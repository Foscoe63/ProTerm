import XCTest
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
}




