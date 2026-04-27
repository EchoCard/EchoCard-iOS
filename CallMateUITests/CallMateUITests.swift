import XCTest

final class CallMateUITests: XCTestCase {
    private enum LaunchArgument {
        static let uiTesting = "-callmate-ui-testing"
        static let forceMain = "-callmate-ui-force-main"
        static let skipBootstrap = "-callmate-ui-skip-bootstrap"
        static let language = "-callmate-ui-language"
        static let seedCalls = "-callmate-ui-seed-calls"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMainTabsAndDeviceModalSmoke() throws {
        let app = configuredApp()
        app.launch()

        XCTAssertTrue(app.buttons["calls-device-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Call Out"].waitForExistence(timeout: 5))

        app.buttons["calls-device-button"].tap()
        XCTAssertTrue(app.buttons["device-modal-close-button"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testTabSwitchSmoke() throws {
        let app = configuredApp()
        app.launch()

        let receiveTab = app.tabBars.buttons["Receive"]
        let callOutTab = app.tabBars.buttons["Call Out"]

        XCTAssertTrue(app.buttons["calls-device-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(callOutTab.waitForExistence(timeout: 5))

        callOutTab.tap()
        XCTAssertTrue(waitForSelection(of: callOutTab))

        receiveTab.tap()
        XCTAssertTrue(waitForSelection(of: receiveTab))
        XCTAssertTrue(app.buttons["calls-device-button"].waitForExistence(timeout: 10))
        app.terminate()
    }

    func testCallsListScrollSmoke() throws {
        let app = configuredApp(seedCallCount: 40)
        app.launch()

        let scrollSurface = app.scrollViews.firstMatch
        let firstRow = app.buttons["calls-row-18880000000"]
        let targetRow = app.buttons["calls-row-18880000014"]

        XCTAssertTrue(scrollSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(targetRow, using: scrollSurface, maxSwipes: 8))
        app.terminate()
    }

    func testCallsListScrollPerformanceSmoke() throws {
        let app = configuredApp(seedCallCount: 40)
        app.launch()

        let scrollSurface = app.scrollViews.firstMatch
        let firstRow = app.buttons["calls-row-18880000000"]
        let targetRow = app.buttons["calls-row-18880000014"]

        XCTAssertTrue(scrollSurface.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))

        let startTime = CFAbsoluteTimeGetCurrent()
        XCTAssertTrue(scrollToElement(targetRow, using: scrollSurface, maxSwipes: 8))
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        XCTAssertLessThan(elapsed, 35)

        app.terminate()
    }

    private func configuredApp(seedCallCount: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            LaunchArgument.uiTesting,
            LaunchArgument.forceMain,
            LaunchArgument.skipBootstrap,
            LaunchArgument.language,
            "en",
        ]
        if let seedCallCount {
            app.launchArguments += [LaunchArgument.seedCalls, "\(seedCallCount)"]
        }
        return app
    }

    private func waitForSelection(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 2) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func scrollToElement(
        _ element: XCUIElement,
        using scrollSurface: XCUIElement,
        maxSwipes: Int
    ) -> Bool {
        if waitForHittable(element, timeout: 1) {
            return true
        }

        for _ in 0..<maxSwipes {
            scrollSurface.swipeUp()
            if waitForHittable(element, timeout: 2) {
                return true
            }
        }
        return waitForHittable(element, timeout: 3)
    }
}
