import XCTest

/// Minimal smoke coverage so the UI test target actually builds a bundle.
///
/// The target previously had no sources at all, which made `xcodebuild test` fail
/// before any test could run. These checks stay deliberately shallow: they verify the
/// app launches and stays up, nothing about specific layout.
final class ProTermSmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppLaunchesAndStaysRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-ProTermUITesting"]
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "ProTerm should reach the foreground after launch")

        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "ProTerm should exit cleanly when terminated")
    }
}
