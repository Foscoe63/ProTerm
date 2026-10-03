import XCTest
@testable import ProTerm

final class RecordingTests: XCTestCase {
    func testCastRoundTripPreservesSpecialCharacters() throws {
        let chunks = ["hello \"world\"\r\n", "\u{1B}[31mred\u{1B}[0m\n", "unicode ✓ 日本\n", "back\\slash\n"]
        var file = CastFile.headerLine(columns: 100, rows: 30, title: "t", timestamp: Date()) + "\n"
        for (i, chunk) in chunks.enumerated() { file += CastFile.eventLine(time: Double(i) * 0.5, text: chunk) + "\n" }

        let recording = try XCTUnwrap(CastFile.parse(Data(file.utf8)))
        XCTAssertEqual(recording.width, 100)
        XCTAssertEqual(recording.height, 30)
        XCTAssertEqual(recording.events.map(\.text), chunks)
        XCTAssertEqual(recording.duration, 1.5, accuracy: 0.001)
    }

    func testParseRejectsNonCastAndSkipsBadLines() {
        XCTAssertNil(CastFile.parse(Data("not json".utf8)))
        let file = CastFile.headerLine(columns: 80, rows: 24, title: "", timestamp: Date())
            + "\ngarbage\n[0.1,\"i\",\"typed\"]\n[0.2,\"o\",\"kept\"]\n"
        XCTAssertEqual(CastFile.parse(Data(file.utf8))?.events.map(\.text), ["kept"])
    }

    func testRenderAppliesLineNormalizationUpToCount() {
        let events = [CastFile.Event(time: 0, text: "a\r\n"), CastFile.Event(time: 1, text: "b\n"),
                      CastFile.Event(time: 2, text: "c\n")]
        XCTAssertEqual(CastFile.render(events, count: 2), "a\nb\n")
        XCTAssertEqual(CastFile.render(events, count: 0), "")
    }

    @MainActor
    func testRecorderWritesParsableFile() throws {
        let recorder = try XCTUnwrap(SessionRecorder(columns: 80, rows: 24, title: "unit-test"))
        recorder.record("one\n")
        recorder.record("two\n")
        recorder.stop()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        let parsed = try XCTUnwrap(CastFile.parse(try Data(contentsOf: recorder.url)))
        XCTAssertEqual(parsed.events.map(\.text), ["one\n", "two\n"])
        XCTAssertEqual(parsed.title, "unit-test")
    }
}
