import XCTest
import Network
@testable import ProTerm

/// Serves one canned HTTP response on localhost so the streaming parsers run against real bytes.
private final class StubServer: @unchecked Sendable {
    let listener: NWListener
    private(set) var lastRequest = ""
    var port: UInt16 { listener.port!.rawValue }

    init(status: Int = 200, body: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "stub")
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: queue)
            var buffer = Data()
            func readRequest() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    buffer.append(data ?? Data())
                    let text = String(decoding: buffer, as: UTF8.self)
                    // Wait for the whole request: headers plus Content-Length bytes of body.
                    if let end = text.range(of: "\r\n\r\n") {
                        let length = text.lowercased().components(separatedBy: "content-length: ").dropFirst().first
                            .flatMap { Int($0.prefix(while: { $0.isNumber })) } ?? 0
                        if buffer.count - text[..<end.upperBound].utf8.count < length { return readRequest() }
                    } else if data != nil { return readRequest() }
                    self?.lastRequest = text
                    let head = "HTTP/1.1 \(status) X\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            readRequest()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }
    deinit { listener.cancel() }
}

final class AIProviderTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""
        for try await chunk in stream { out += chunk }
        return out
    }

    func testOpenAICompatibleStreamsDeltas() async throws {
        let body = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]

        """
        let server = try StubServer(body: body)
        let provider = OpenAICompatibleProvider(
            baseURL: "http://127.0.0.1:\(server.port)/v1", apiKey: "k", model: "m", displayName: "Stub")
        let text = try await collect(provider.stream(messages: [AIChatMessage(role: .user, content: "hi")], system: "sys"))
        XCTAssertEqual(text, "Hello")
        XCTAssertTrue(server.lastRequest.contains("POST /v1/chat/completions"))
        XCTAssertTrue(server.lastRequest.contains("Bearer k"))
    }

    func testAnthropicStreamsTextDeltasAndSendsHeaders() async throws {
        let body = """
        event: message_start
        data: {"type":"message_start"}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let server = try StubServer(body: body)
        var provider = AnthropicProvider(apiKey: "sk-test", model: "claude-sonnet-5-5")
        provider.endpoint = URL(string: "http://127.0.0.1:\(server.port)/v1/messages")!
        let text = try await collect(provider.stream(messages: [AIChatMessage(role: .user, content: "hi")], system: "s"))
        XCTAssertEqual(text, "Hi there")
        let request = server.lastRequest.lowercased()
        XCTAssertTrue(request.contains("x-api-key: sk-test"))
        XCTAssertTrue(request.contains("anthropic-version: 2023-06-01"))
        XCTAssertTrue(request.contains("\"stream\":true"))
    }

    func testAnthropicErrorEventThrows() async throws {
        let body = "data: {\"type\":\"error\",\"error\":{\"message\":\"overloaded\"}}\n\n"
        let server = try StubServer(body: body)
        var provider = AnthropicProvider(apiKey: "k", model: "m")
        provider.endpoint = URL(string: "http://127.0.0.1:\(server.port)/v1/messages")!
        do {
            _ = try await collect(provider.stream(messages: [AIChatMessage(role: .user, content: "x")], system: ""))
            XCTFail("expected error")
        } catch let error as AIError {
            XCTAssertTrue(error.message.contains("overloaded"))
        }
    }

    func testHTTPErrorSurfacesServerMessage() async throws {
        let server = try StubServer(status: 401, body: #"{"error":{"message":"bad key"}}"#)
        let provider = OpenAICompatibleProvider(
            baseURL: "http://127.0.0.1:\(server.port)", apiKey: nil, model: "", displayName: "Stub")
        do {
            _ = try await collect(provider.stream(messages: [AIChatMessage(role: .user, content: "x")], system: ""))
            XCTFail("expected error")
        } catch let error as AIError {
            XCTAssertTrue(error.message.contains("401") && error.message.contains("bad key"), error.message)
        }
    }

    func testBuiltInHelpAnswersKnownTopic() async throws {
        let text = try await collect(BuiltInHelpProvider().stream(
            messages: [AIChatMessage(role: .user, content: "how do I make a symlink")], system: ""))
        XCTAssertTrue(text.contains("ln -s"))
    }
}
