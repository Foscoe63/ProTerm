import XCTest
import SwiftUI
@testable import ProTerm

final class OutputStylerTests: XCTestCase {
    private func filter(_ pattern: String, _ action: ProductivityTools.OutputFilter.FilterAction,
                        regex: Bool = false, replacement: String? = nil) -> ProductivityTools.OutputFilter {
        ProductivityTools.OutputFilter(
            id: UUID(), name: "t", pattern: pattern, isRegex: regex, action: action,
            color: "#FFD700", replacement: replacement, isEnabled: true)
    }

    private func run(_ text: String, _ filters: [ProductivityTools.OutputFilter], colorCode: Bool = false) -> String {
        String(OutputStyler.apply(
            rules: OutputStyler.compile(filters), colorCode: colorCode, to: AttributedString(text)).characters)
    }

    func testHideDropsMatchingCompleteLinesOnly() {
        XCTAssertEqual(run("a\nnoise here\nb\n", [filter("noise", .hide)]), "a\nb\n")
    }

    func testPartialTrailingLineIsNeverHidden() {
        XCTAssertEqual(run("a\nuser@host$ noise", [filter("noise", .hide)]), "a\nuser@host$ noise")
    }

    func testExtractKeepsOnlyMatchingLines() {
        XCTAssertEqual(run("x\nerr 1\ny\nerr 2\n", [filter("err", .extract)]), "err 1\nerr 2\n")
    }

    func testReplaceLiteralAndRegexWithGroups() {
        XCTAssertEqual(run("token=abc\n", [filter("abc", .replace, replacement: "***")]), "token=***\n")
        XCTAssertEqual(run("id 42\n", [filter(#"id (\d+)"#, .replace, regex: true, replacement: "#$1")]), "#42\n")
    }

    func testHighlightAddsBackgroundWithoutChangingText() {
        let out = OutputStyler.apply(
            rules: OutputStyler.compile([filter("warn", .highlight)]), colorCode: false,
            to: AttributedString("a warn b\n"))
        XCTAssertEqual(String(out.characters), "a warn b\n")
        XCTAssertTrue(out.runs.contains { $0.backgroundColor != nil })
    }

    func testColorCodingRespectsExistingAnsiColor() {
        var colored = AttributedString("error")
        colored.foregroundColor = .blue
        var input = colored
        input.append(AttributedString(" failed\n"))
        let out = OutputStyler.apply(rules: [], colorCode: true, to: input)
        let blueRuns = out.runs.filter { $0.foregroundColor == .blue }
        XCTAssertEqual(String(out[blueRuns.first!.range].characters), "error")
        XCTAssertTrue(out.runs.contains { $0.foregroundColor != nil && $0.foregroundColor != .blue })
    }

    func testInvalidRegexIsIgnored() {
        XCTAssertEqual(run("a\n", [filter("(", .hide, regex: true)]), "a\n")
    }
}
