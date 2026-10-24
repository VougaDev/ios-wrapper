import UIKit
import WebKit

/// COOKIE AND DATA CONSENT, AS A NATIVE DIALOG, asked once, never the website's banner over the web view. Each purpose is
/// off until the person turns it on. The choice goes to the site as a first-party cookie
/// (`<cookieName>=<purpose>:1|<purpose>:0`), so the site hides its own banner and honours it; pages read it too through
/// `VougaDevNative.consent()` (`{<purpose>: true|false}`). It can be changed in Settings, "Privacy and data".
@MainActor
public final class ShellConsent {

    public struct Purpose {
        public var key: String
        /// In the person's language: the app passes its own localized texts.
        public var title: String
        public var detail: String

        public init(key: String, title: String, detail: String) {
            self.key = key
            self.title = title
            self.detail = detail
        }
    }

    public struct Settings {
        public var purposes: [Purpose]
        public var cookieName: String

        public init(purposes: [Purpose], cookieName: String = "vougadev_consent") {
            self.purposes = purposes
            self.cookieName = cookieName
        }
    }

    let settings: Settings
    private let origin: AppOrigin
    private let defaults: UserDefaults

    init(settings: Settings, origin: AppOrigin, defaults: UserDefaults) {
        self.settings = settings
        self.origin = origin
        self.defaults = defaults
    }

    /// The person's answer per purpose; nil until asked.
    var choices: [String: Bool]? { defaults.dictionary(forKey: "consent.choices") as? [String: Bool] }

    /// `consent()`: `{<purpose>: true|false}` for every purpose, all false before the person answered.
    func state() -> JSONObject {
        Dictionary(settings.purposes.map { ($0.key, choices?[$0.key] == true) }, uniquingKeysWith: { first, _ in first })
    }

    /// [then] runs once the person answered, at once when they already did (unless [again], from Settings).
    func ask(from presenter: UIViewController, again: Bool = false, then: @escaping () -> Void) {
        if let choices, !again {
            Task { await self.setCookie(choices); then() }
            return
        }
        let lines = settings.purposes.map { "• \($0.title): \($0.detail)" }.joined(separator: "\n")
        let alert = UIAlertController(title: Strings.text("consent_title"),
                                      message: Strings.text("consent_text") + "\n\n" + lines, preferredStyle: .alert)
        let answer = { (yes: Bool) in
            let chosen = Dictionary(self.settings.purposes.map { ($0.key, yes) }, uniquingKeysWith: { first, _ in first })
            self.defaults.set(chosen, forKey: "consent.choices")
            Task { await self.setCookie(chosen); then() }
        }
        alert.addAction(UIAlertAction(title: Strings.text("consent_refuse"), style: .default) { _ in answer(false) })
        alert.addAction(UIAlertAction(title: Strings.text("consent_accept"), style: .default) { _ in answer(true) })
        var top = presenter
        while let shown = top.presentedViewController { top = shown }
        top.present(alert, animated: true)
    }

    /// `analytics:1|ads:0`, in the purposes' order.
    func cookieValue(_ choices: [String: Bool]) -> String {
        settings.purposes.map { "\($0.key):\(choices[$0.key] == true ? 1 : 0)" }.joined(separator: "|")
    }

    func cookie(_ choices: [String: Bool]) -> HTTPCookie? {
        HTTPCookie(properties: [
            .name: settings.cookieName, .value: cookieValue(choices), .domain: origin.host, .path: "/",
            .secure: origin.scheme == "https" ? "TRUE" : "FALSE", .expires: Date().addingTimeInterval(365 * 24 * 3600),
        ])
    }

    private func setCookie(_ choices: [String: Bool]) async {
        guard let cookie = cookie(choices) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
    }
}
