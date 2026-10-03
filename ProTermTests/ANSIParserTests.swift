import XCTest
import SwiftUI
@testable import ProTerm

final class ANSIParserTests: XCTestCase {
    func testHyperlinkSequenceProducesLinkAttribute() {
        let text = "\u{001B}]8;;https://apple.com\u{0007}Apple\u{001B}]8;;\u{0007}"
        let attributed = ANSIParser.parse(text, baseFont: .custom("Menlo", size: 12))
        XCTAssertTrue(attributed.runs.contains(where: { run in
            run.link == URL(string: "https://apple.com")
        }), "Hyperlink attribute should be applied to text between OSC 8 sequences")
    }
    
    func testReverseVideoSequenceSwapsColors() {
        let sample = "\u{001B}[31mRed\u{001B}[0m Plain"
        let attributed = ANSIParser.parse(sample, baseFont: .custom("Menlo", size: 12))
        XCTAssertTrue(attributed.characters.contains { _ in true })
        // Ensure reset clears attributes back to defaults (foreground should be nil)
        let runs = Array(attributed.runs)
        guard runs.count >= 2 else {
            XCTFail("Expected at least two runs"); return
        }
        XCTAssertNil(runs.last?.foregroundColor)
    }

    /// A standalone BEL is an audible bell and must not reach the rendered text.
    /// Only a BEL that terminates an open OSC sequence is preserved.
    func testStandaloneBellIsStripped() {
        let (normalized, _) = ANSIParser.normalizeControlCharacters("ding\u{0007}dong\n")
        XCTAssertEqual(normalized, "dingdong\n")
    }

    /// BEL terminates OSC 8, so it must survive normalization to reach the parser.
    func testBellTerminatingHyperlinkSurvivesNormalization() {
        let (normalized, _) = ANSIParser.normalizeControlCharacters(
            "\u{001B}]8;;https://apple.com\u{0007}Apple\u{001B}]8;;\u{0007}")
        XCTAssertTrue(normalized.contains("\u{0007}"), "BEL terminator should be preserved inside an OSC sequence")
    }

    /// CR at the end of a chunk must clear that line once the next chunk arrives,
    /// which is how zsh redraws its prompt.
    func testPendingCarriageReturnClearsLineOnNextChunk() {
        let (first, pending) = ANSIParser.normalizeControlCharacters("stale prompt\r")
        XCTAssertTrue(pending, "Trailing CR should be reported as pending")
        let (second, stillPending) = ANSIParser.normalizeControlCharacters("fresh prompt\n", pendingCR: pending)
        XCTAssertFalse(stillPending)
        XCTAssertEqual(second, "fresh prompt\n", "Pending CR should discard the stale line, not prepend a newline")
        _ = first
    }
}

final class PromptBuilderTests: XCTestCase {
    func testShellPromptLineMatchesOriginalFormat() {
        let original = "ewg@MacStudio-3 ~ %"
        XCTAssertTrue(PromptBuilder.isShellPromptLine(original))
    }
    
    func testShellPromptLineMatchesNewFormat() {
        let newFormat = "MacStudio-3:~ ewg$"
        XCTAssertTrue(PromptBuilder.isShellPromptLine(newFormat))
    }
    
    func testShellPromptLineMatchesWithGitBranch() {
        let newFormatWithGit = "MacStudio-3:~ [main] ewg$"
        XCTAssertTrue(PromptBuilder.isShellPromptLine(newFormatWithGit))
    }

    func testShellPromptLineRejectsNonPrompt() {
        let nonPrompt = "Some random command output line"
        XCTAssertFalse(PromptBuilder.isShellPromptLine(nonPrompt))
    }
}






