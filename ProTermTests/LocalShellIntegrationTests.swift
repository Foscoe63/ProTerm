import XCTest
@testable import ProTerm

/// Runs a real login shell to confirm markers line up with the echoed command and recording captures output.
@MainActor
final class LocalShellIntegrationTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    func testMarkerHeaderAndRecordingWithRealShell() async throws {
        let session = TerminalSession(shellManager: ShellManager())
        session.startLoginShellIfNeeded()
        let ready = await waitUntil { session.hasActivePTY && session.canAcceptLoginShellInput }
        try XCTSkipUnless(ready, "login shell did not start in this environment")
        try await Task.sleep(nanoseconds: 1_500_000_000)  // let the startup banner settle

        let recordingURL = try XCTUnwrap(session.startRecording(title: "integration"))
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        session.markCommandSubmitted("echo ZQX9")
        session.sendInput("echo ZQX9\n")
        let echoed = await waitUntil { session.output.contains("\nZQX9") }
        XCTAssertTrue(echoed, "expected the command output after the echo; got \(session.output.debugDescription)")

        session.stopRecording()
        let recording = try XCTUnwrap(CastFile.parse(try Data(contentsOf: recordingURL)))
        XCTAssertTrue(recording.events.contains { $0.text.contains("ZQX9") })

        let marker = try XCTUnwrap(session.commandMarkers.last)
        // The shell's trailing newline sometimes only arrives with the next prompt; a finished line is needed to fold.
        let output = session.output.hasSuffix("\n") ? session.output : session.output + "\n"
        let folded = CommandSections.fold(output, markers: [marker], collapsed: [marker.id])
        XCTAssertTrue(folded.contains("hidden"), "header should be found and body folded: \(folded.debugDescription)")
    }
}
