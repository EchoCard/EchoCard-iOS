import XCTest

final class CallMateUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments += [
                "-callmate-ui-testing",
                "-callmate-ui-force-main",
                "-callmate-ui-skip-bootstrap",
                "-callmate-ui-language",
                "en",
            ]
            app.launch()
        }
    }
}
