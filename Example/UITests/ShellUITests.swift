import XCTest

/// The shell's own screens as a person sees them, signed out, on the Simulator. The example app's site does not exist
/// (`app.example.org`), which is what makes its page load fail into the native offline screen.
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

    func testSignInOpensTheSystemSignInSheetNeverAWebPage() {
        let app = launch("en")
        app.buttons["shell.panel.button"].tap()
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "ASWebAuthenticationSession asks to use the account service's site")
        XCTAssertTrue(prompt.buttons["Continue"].exists)
        snapshot(self, "signin-sheet")
        prompt.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["shell.panel.button"].waitForExistence(timeout: 15), "cancelled: back on the sign-in screen")
    }

    func testAPageThatCannotLoadShowsTheNativeOfflineScreen() {
        let app = launch("fr")
        app.buttons["shell.panel.link"].tap()
        let title = app.staticTexts["shell.panel.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        let offline = NSPredicate(format: "label == %@", "La page n'a pas pu être chargée")
        expectation(for: offline, evaluatedWith: title)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(app.buttons["shell.panel.button"].label, "Réessayer")
        snapshot(self, "offline-fr")
    }
}

/// A screenshot kept with the test results; the workflow exports them (`xcresulttool export attachments`).
func snapshot(_ test: XCTestCase, _ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
}
