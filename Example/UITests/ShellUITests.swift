import XCTest

/// The shell's own screens as a person sees them, signed out, on the Simulator. The example app's site does not exist
/// (`app.example.org`, `auth.example.org`), which is what makes its loads fail into the native offline screens.
final class ShellUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "\(language)_\(language.uppercased())"]
        app.launch()
        return app
    }

    func testTheSignInScreenSpeaksEnglishFrenchAndSpanish() {
        for (language, label) in [("en", "Sign in with VougaDev"), ("fr", "Se connecter avec VougaDev"), ("es", "Iniciar sesión con VougaDev")] {
            let app = launch(language)
            let button = app.buttons["shell.panel.button"]
            XCTAssertTrue(button.waitForExistence(timeout: 30), language)
            XCTAssertEqual(button.label, label, language)
            XCTAssertTrue(app.buttons["shell.panel.link"].exists, "the privacy policy is a tap away (\(language))")
            snapshot(self, "signin-\(language)")
            app.terminate()
        }
    }

    /// The example's account service does not exist either: signing in says so natively, with Try again.
    func testSigningInWithoutTheAccountServiceSaysSoNatively() {
        let app = launch("en")
        app.buttons["shell.panel.button"].tap()
        let text = app.staticTexts["shell.panel.text"]
        let offline = NSPredicate(format: "label BEGINSWITH %@", "Offline:")
        expectation(for: offline, evaluatedWith: text)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.buttons["shell.panel.button"].label, "Try again")
        snapshot(self, "signin-offline")
    }

    /// Nothing kept on the phone yet and the site out of reach: the app's own welcome, never an error page.
    func testWithNothingKeptTheAppWelcomesInsteadOfAnError() {
        let app = launch("fr")
        app.buttons["shell.panel.link"].tap()
        let text = app.staticTexts["shell.panel.text"]
        let welcome = NSPredicate(format: "label BEGINSWITH %@", "Connectez-vous à Internet une première fois")
        expectation(for: welcome, evaluatedWith: text)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.buttons["shell.panel.button"].exists, "no lone Try again")
        snapshot(self, "offline-welcome-fr")
    }
}

/// A screenshot kept with the test results; the workflow exports them (`xcresulttool export attachments`).
func snapshot(_ test: XCTestCase, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
}
