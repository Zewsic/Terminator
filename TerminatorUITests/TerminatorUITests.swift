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
        displayName.click()
        displayName.typeText("UI Test Host\t")
        app.typeText("example.test\t")
        app.typeText("tester")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["UI Test Host"].waitForExistence(timeout: 3))
    }
}
