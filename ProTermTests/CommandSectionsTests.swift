import XCTest
import SwiftUI
@testable import ProTerm

final class CommandSectionsTests: XCTestCase {
    private func offset(of needle: String, in text: String, end: Bool = false) -> Int {
        let range = text.range(of: needle)!
        return text.utf16.distance(from: text.startIndex, to: end ? range.upperBound : range.lowerBound)
    }

    private func visible(_ folded: String) -> String {
        String(ANSIParser.parse(folded, baseFont: .custom("Menlo", size: 12)).characters)
    }

    func testLocalStyleHeaderAfterMarker() {
        let out = "echo hi\nhi\nls\na\nb\n"
        let first = CommandMarker(offset: 0, command: "echo hi")
        let second = CommandMarker(offset: offset(of: "ls", in: out), command: "ls")

        let expanded = visible(CommandSections.fold(out, markers: [first, second], collapsed: []))
        XCTAssertEqual(expanded, "▾ echo hi\nhi\n▾ ls\na\nb\n")

        let collapsed = visible(CommandSections.fold(out, markers: [first, second], collapsed: [first.id]))
        XCTAssertEqual(collapsed, "▸ echo hi\n    … 1 line hidden (click to expand)\n▾ ls\na\nb\n")
    }

    func testRemoteStyleHeaderIsTheLineContainingTheMarker() {
        let out = "router# show run\nline1\nline2\nrouter# show ver\nv1\n"
        let m1 = CommandMarker(offset: offset(of: "router# show run", in: out, end: true), command: "show run")
        let m2 = CommandMarker(offset: offset(of: "router# show ver", in: out, end: true), command: "show ver")
        let collapsed = visible(CommandSections.fold(out, markers: [m1, m2], collapsed: [m1.id]))
        XCTAssertEqual(collapsed, "▸ router# show run\n    … 2 lines hidden (click to expand)\n▾ router# show ver\nv1\n")
    }

    func testLivePromptLineIsNeverFolded() {
        let out = "ls\na\nb\nuser@host $ "
        let marker = CommandMarker(offset: 0, command: "ls")
        let folded = visible(CommandSections.fold(out, markers: [marker], collapsed: [marker.id]))
        XCTAssertTrue(folded.hasSuffix("user@host $ "))
        XCTAssertTrue(folded.contains("2 lines hidden"))
    }

    func testMarkerWhoseEchoIsMissingIsIgnored() {
        let out = "something else\nbody\n"
        let marker = CommandMarker(offset: 0, command: "ls -la")
        XCTAssertEqual(CommandSections.fold(out, markers: [marker], collapsed: [marker.id]), out)
    }

    func testWrappedEchoIsTreatedAsOneHeader() {
        let out = "ec\nho hello world\nhello world\n"
        let marker = CommandMarker(offset: 0, command: "echo hello world")
        let collapsed = visible(CommandSections.fold(out, markers: [marker], collapsed: [marker.id]))
        XCTAssertEqual(collapsed, "▸ ec\nho hello world\n    … 1 line hidden (click to expand)\n")
    }

    func testHeaderWithNoBodyGetsNoControls() {
        let out = "true\nuser@host $ "
        let marker = CommandMarker(offset: 0, command: "true")
        XCTAssertEqual(visible(CommandSections.fold(out, markers: [marker], collapsed: [])), out)
    }

    func testFoldLinksSurviveParsingAndResolveToMarkerID() {
        let out = "ls\na\n"
        let marker = CommandMarker(offset: 0, command: "ls")
        let attributed = ANSIParser.parse(CommandSections.fold(out, markers: [marker], collapsed: []),
                                          baseFont: .custom("Menlo", size: 12))
        let urls = attributed.runs.compactMap(\.link)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertEqual(CommandSections.id(from: urls[0]), marker.id)
    }
}
