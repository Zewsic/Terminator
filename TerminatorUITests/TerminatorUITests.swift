import XCTest

@MainActor
final class TerminatorUITests: XCTestCase {
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchAndOpenHosts() throws {
        let app = makeApp()
        app.launch()

        let sidebar = app.outlines["main-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.staticTexts["Hosts"].click()
        XCTAssertTrue(
            app.buttons["add-host"].waitForExistence(timeout: 3)
                || app.buttons["add-host-empty"].waitForExistence(timeout: 3)
        )
    }

    func testCreateHost() throws {
        let app = makeApp()
        app.launch()
        let sidebar = app.outlines["main-sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        sidebar.staticTexts["Hosts"].click()

        let addButton = app.buttons["add-host"].exists ? app.buttons["add-host"] : app.buttons["add-host-empty"]
        addButton.click()
        let displayName = app.textFields["host-display-name"]
        XCTAssertTrue(displayName.waitForExistence(timeout: 3))
        let hostname = app.textFields["host-hostname"]
        hostname.click()
        hostname.typeText("example.test")
        let username = app.textFields["host-username"]
        username.click()
        username.typeText("tester")
        app.buttons["save-host"].click()

        XCTAssertTrue(app.staticTexts["example.test"].waitForExistence(timeout: 5))
    }
}
