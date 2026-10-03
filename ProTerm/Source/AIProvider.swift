import Foundation

// MARK: - Provider abstraction

struct AIChatMessage: Equatable {
    enum Role: String { case user, assistant }
    let role: Role
    let content: String
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A chat backend that streams its reply as text chunks.
protocol AIProvider: Sendable {
    func stream(messages: [AIChatMessage], system: String) -> AsyncThrowingStream<String, Error>
}

// MARK: - Shared SSE plumbing

private enum SSE {
    /// Sends the request and yields the JSON payload of each `data:` line.
    static func payloads(for request: URLRequest, providerName: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIError(message: "\(providerName): invalid response")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 1500 { break }
                        }
                        throw AIError(message: "\(providerName) returned \(http.statusCode): \(errorText(from: body))")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8) { continuation.yield(data) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func errorText(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return body.isEmpty ? "no details" : body
    }
}

// MARK: - Anthropic

struct AnthropicProvider: AIProvider {
    let apiKey: String
    let model: String
    var maxTokens = 2048
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(messages: [AIChatMessage], system: String) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let events = SSE.payloads(for: request, providerName: "Anthropic")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in events {
                        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        switch event["type"] as? String {
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "error":
                            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                            throw AIError(message: "Anthropic: \(message)")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI-compatible (LM Studio, OpenAI, Ollama, ...)

struct OpenAICompatibleProvider: AIProvider {
    let baseURL: String
    let apiKey: String?
    let model: String
    let displayName: String

    func stream(messages: [AIChatMessage], system: String) -> AsyncThrowingStream<String, Error> {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + "/v1/chat/completions") else {
            return AsyncThrowingStream { $0.finish(throwing: AIError(message: "Invalid server URL: \(baseURL)")) }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var wire: [[String: String]] = [["role": "system", "content": system]]
        wire += messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": model.isEmpty ? "local-model" : model,
            "messages": wire,
            "stream": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let events = SSE.payloads(for: request, providerName: displayName)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in events {
                        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let choices = event["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Built-in offline help

/// Keyword-based command cheat sheet. Not an AI model; it needs no network or key.
struct BuiltInHelpProvider: AIProvider {
    func stream(messages: [AIChatMessage], system: String) -> AsyncThrowingStream<String, Error> {
        let query = messages.last(where: { $0.role == .user })?.content ?? ""
        let answer = Self.answer(to: query)
        return AsyncThrowingStream { continuation in
            continuation.yield(answer)
            continuation.finish()
        }
    }

    static func answer(to query: String) -> String {
        // Simple text-based assistant that answers terminal-related questions
        let lowerQuery = query.lowercased()
        
        // Handle common terminal command questions
        if lowerQuery.contains("symbolic link") || lowerQuery.contains("symlink") || lowerQuery.contains("ln -s") {
            return "To create a symbolic link, use: `ln -s <target> <link_name>`\n\nExample: `ln -s /path/to/file /path/to/link`\n\nThis creates a symbolic link named 'link' that points to 'file'. The `-s` flag creates a symbolic (soft) link rather than a hard link."
        }
        
        if lowerQuery.contains("list files") || lowerQuery.contains("ls") || lowerQuery.contains("directory") {
            return "To list files in a directory, use: `ls`\n\nCommon options:\n- `ls -l` - Long format with details\n- `ls -a` - Show hidden files\n- `ls -la` - Long format including hidden files\n- `ls -lh` - Human-readable file sizes\n- `ls -lt` - Sort by modification time"
        }
        
        if lowerQuery.contains("find") && (lowerQuery.contains("file") || lowerQuery.contains("search")) {
            return "To find files, use: `find <directory> -name <pattern>`\n\nExamples:\n- `find . -name \"*.txt\"` - Find all .txt files in current directory\n- `find ~ -name \"file.txt\"` - Find file.txt in home directory\n- `find / -type f -name \"*.log\"` - Find all .log files on the system"
        }
        
        if lowerQuery.contains("grep") || lowerQuery.contains("search") && lowerQuery.contains("text") {
            return "To search for text in files, use: `grep <pattern> <file>`\n\nExamples:\n- `grep \"error\" file.txt` - Find lines containing 'error'\n- `grep -r \"pattern\" .` - Recursively search in all files\n- `grep -i \"pattern\" file.txt` - Case-insensitive search\n- `grep -n \"pattern\" file.txt` - Show line numbers"
        }
        
        if lowerQuery.contains("permission") || lowerQuery.contains("chmod") {
            return "To change file permissions, use: `chmod <mode> <file>`\n\nExamples:\n- `chmod 755 file.sh` - Owner: read/write/execute, Others: read/execute\n- `chmod +x file.sh` - Add execute permission\n- `chmod u+w file.txt` - Add write permission for owner\n\nCommon modes: 755 (executable), 644 (readable), 600 (private)"
        }
        
        if lowerQuery.contains("process") || lowerQuery.contains("ps") || lowerQuery.contains("running") {
            return "To view running processes:\n\n- `ps aux` - List all processes\n- `ps aux | grep <name>` - Find specific process\n- `top` - Interactive process monitor\n- `htop` - Enhanced process monitor (if installed)\n- `kill <pid>` - Terminate a process\n- `killall <name>` - Kill all processes by name"
        }
        
        if lowerQuery.contains("network") || lowerQuery.contains("ip") || lowerQuery.contains("ifconfig") {
            return "Network commands:\n\n- `ifconfig` - Show network interfaces\n- `ip addr` - Show IP addresses (Linux-style)\n- `netstat -rn` - Show routing table\n- `ping <host>` - Test connectivity\n- `curl <url>` - Download/request from URL\n- `wget <url>` - Download file (if installed)"
        }
        
        if lowerQuery.contains("git") {
            return "Common Git commands:\n\n- `git status` - Show repository status\n- `git add <file>` - Stage files\n- `git commit -m \"message\"` - Commit changes\n- `git push` - Push to remote\n- `git pull` - Pull from remote\n- `git branch` - List branches\n- `git checkout <branch>` - Switch branch\n- `git log` - View commit history"
        }
        
        if lowerQuery.contains("help") || lowerQuery.contains("how") || lowerQuery.contains("what") {
            return "I can help you with terminal commands! Try asking about:\n\n- File operations (ls, cp, mv, rm)\n- Text search (grep, find)\n- Permissions (chmod, chown)\n- Processes (ps, top, kill)\n- Network (ifconfig, ping, curl)\n- Git commands\n- Symbolic links\n- And more!\n\nJust ask me a question about any terminal command or operation."
        }
        
        // Default helpful response
        return "I'm here to help with terminal commands and macOS operations. You asked: \"\(query)\"\n\nTry asking me about specific commands like:\n- How to create a symbolic link\n- How to find files\n- How to search text in files\n- Git commands\n- File permissions\n- Network commands\n\nOr ask me 'help' for more information!"
    }
}
