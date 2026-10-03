import XCTest
@testable import ProTerm

final class CompletionEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("My Folder"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".hidden").path, contents: nil)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func run(_ line: String, history: [String] = [], remote: Bool = false) -> CompletionEngine.Result {
        CompletionEngine.complete(
            line: line, cwd: dir, history: history, aliases: ["ll"], executables: ["git", "grep", "gzip"], isRemote: remote)
    }

    func testCommandNamesComeFromPathAliasesAndHistory() {
        XCTAssertEqual(run("gi").candidates, ["git"])
        XCTAssertEqual(run("l").candidates, ["ll"])
        XCTAssertTrue(run("dep", history: ["deploy --prod"]).candidates.contains("deploy"))
    }

    func testPathCompletionInArgumentPosition() {
        XCTAssertEqual(run("cat no").candidates, ["notes.txt"])
        XCTAssertEqual(run("ls Doc").candidates, ["Documents/"])
    }

    func testSpacesAreEscapedAndHiddenFilesNeedDot() {
        XCTAssertEqual(run("ls My").candidates, ["My\\ Folder/"])
        XCTAssertFalse(run("ls ").candidates.contains(".hidden"))
        XCTAssertEqual(run("ls .h").candidates, [".hidden"])
    }

    func testCdOnlyOffersDirectories() {
        XCTAssertEqual(run("cd ").candidates, ["Documents/", "My\\ Folder/"])
    }

    func testSubcommandsFromHistoryRankedByFrequency() {
        let history = ["git checkout main", "git commit -m x", "git commit -m y", "git status"]
        XCTAssertEqual(run("git c", history: history).candidates.prefix(2), ["commit", "checkout"])
    }

    func testRemoteSessionsSkipLocalFilesystem() {
        XCTAssertTrue(run("cat no", remote: true).candidates.isEmpty)
    }
}
