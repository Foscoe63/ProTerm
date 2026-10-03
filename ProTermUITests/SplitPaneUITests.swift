import XCTest

/// Drives the real app: Cmd+D must create a second pane whose command field receives the typing.
final class SplitPaneUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func commandFields(_ app: XCUIApplication) -> XCUIElementQuery {
        app.textFields.matching(NSPredicate(format: "label == %@", "Command input field"))
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func testSplitCreatesSecondPaneAndFocusMovesToIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ProTermUITesting"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(waitFor { self.commandFields(app).count >= 1 }, "command field never appeared")
        app.typeKey("t", modifierFlags: .command)  // fresh tab so restored tabs don't matter
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let before = commandFields(app).count

        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(waitFor { self.commandFields(app).count == before + 1 }, "split did not add a command field")

        // Let focus settle, then type: the text must land in the NEW (right-hand) pane.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.typeText("echo SPLITOK123")
        let fields = commandFields(app)
        let values = (0..<fields.count).map { (fields.element(boundBy: $0).value as? String) ?? "" }
        XCTAssertEqual(values.filter { $0.contains("SPLITOK123") }.count, 1, "typed text should be in exactly one pane: \(values)")
        let window = app.windows.firstMatch.frame
        let typedField = (0..<fields.count).map { fields.element(boundBy: $0) }
            .first { (($0.value as? String) ?? "").contains("SPLITOK123") }
        XCTAssertNotNil(typedField)
        XCTAssertGreaterThan(typedField!.frame.midX, window.midX, "typing should go to the right-hand (new) pane")

        // Clicking the other pane's field moves focus there.
        let leftField = (0..<fields.count).map { fields.element(boundBy: $0) }.min { $0.frame.minX < $1.frame.minX }!
        leftField.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.typeText("LEFT")
        XCTAssertTrue(((leftField.value as? String) ?? "").contains("LEFT"), "click should focus the left pane's field")
    }
}
