import XCTest

final class LoginFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignInOpensMicrosoftPageThenSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launch()
        openMicrosoftSignIn(app)
        XCTAssertTrue(
            app.navigationBars["Microsoft Sign In"].waitForExistence(timeout: 8)
                || app.webViews["microsoftSignInWebView"].waitForExistence(timeout: 4),
            "Sign In must show the Microsoft page in-app, not a dead button"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["More"].waitForExistence(timeout: 8))

        if app.buttons["signOutButton"].exists {
            app.tabBars.buttons["More"].tap()
            app.buttons["mailAccountsLink"].tap()
            app.buttons["signOutButton"].tap()
            XCTAssertTrue(app.buttons["addAccountButton"].waitForExistence(timeout: 5))
        }

        openMicrosoftSignIn(app)
        XCTAssertTrue(
            app.navigationBars["Microsoft Sign In"].waitForExistence(timeout: 8)
                || app.webViews["microsoftSignInWebView"].waitForExistence(timeout: 4)
        )
    }

    func testSignInOpensMicrosoftPageAgain() {
        testSignInOpensMicrosoftPageThenSurvivesRelaunch()
    }

    func testSignInOpensMicrosoftPageThirdPass() {
        testSignInOpensMicrosoftPageThenSurvivesRelaunch()
    }

    private func openMicrosoftSignIn(_ app: XCUIApplication) {
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        let accounts = app.descendants(matching: .any)["mailAccountsLink"]
        if accounts.waitForExistence(timeout: 5) {
            accounts.tap()
        } else {
            app.staticTexts["Mail Accounts"].tap()
        }
        let add = app.buttons["addAccountButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let exchange = app.buttons["provider-microsoft"]
        XCTAssertTrue(exchange.waitForExistence(timeout: 5))
        exchange.tap()
        let email = app.textFields["microsoftEmailField"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("lawyer@firm.com")
        app.buttons["microsoftSignInButton"].tap()
    }
}
