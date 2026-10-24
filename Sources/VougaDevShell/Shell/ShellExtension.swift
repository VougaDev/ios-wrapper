import UIKit
import WebKit

/// What an extension may ask of the shell: the session, the site's origin, a page to open, a screen to present over.
@MainActor
public protocol ShellHost: AnyObject {
    var session: AppSession { get }
    /// The controller dialogs and native screens are presented from (the topmost one shown).
    var presenter: UIViewController { get }
    /// A page of the site by absolute URL: a claimed native screen opens instead, anything else loads in the web view.
    func open(_ url: String)
}

/// What an extension needs in the app's Info.plist. The shell checks it at launch (a Debug build stops on a missing key)
/// and `AppSession.missingRequirements()` lists it for a test.
public struct ShellRequirements {
    public var purposeStrings: [String]
    public var backgroundModes: [String]
    /// Keys of `NSLocationTemporaryUsageDescriptionDictionary`.
    public var temporaryLocationPurposes: [String]

    public init(purposeStrings: [String] = [], backgroundModes: [String] = [], temporaryLocationPurposes: [String] = []) {
        self.purposeStrings = purposeStrings
        self.backgroundModes = backgroundModes
        self.temporaryLocationPurposes = temporaryLocationPurposes
    }
}

/// ONE NATIVE FEATURE OF AN APP, beyond the core (VougaDev Native, README.md): its members of `window.VougaDevNative`,
/// the native screens it claims, the notifications it opens, its Info.plist needs and its own disclosure. Shared ones
/// live in this repository as their own targets (`VougaDevTracking`, `VougaDevOfflineMap`); an app's own ones live in the
/// app. A page asks `VougaDevNative.features().includes("<name>")`. Members are fixed in the binary (App Review 2.5.2).
///
/// Every hook has a default: an extension implements what it uses. Everything runs on the main thread.
@MainActor
public protocol ShellExtension: AnyObject {
    /// What `features()` lists: `tracking`, `offline-map`, an app's own (`missions`). Lowercase, words joined by `-`.
    var name: String { get }

    /// Its members of `window.VougaDevNative`, in the order its contract lists them.
    func bridgeMethods(host: ShellHost) -> [(String, NativeBridge.Method)]

    var requirements: ShellRequirements { get }

    /// The session made with this extension: what it keeps (`session.defaults`) and how it calls the site
    /// (`session.caller()`). Called once, before anything else.
    func attach(to session: AppSession)

    /// The web view is being made (a URL scheme handler, a script of its own).
    func configure(_ configuration: WKWebViewConfiguration)

    /// The native screen a same-origin path (no query, trailing slash kept) opens instead of loading, or nil.
    func nativeScreen(path: String, host: ShellHost) -> UIViewController?

    /// The native screen a notification's `screen` key opens, or nil when this extension does not claim the key.
    func notificationScreen(key: String, url: URL?, host: ShellHost) -> UIViewController?

    /// A page of the site finished loading with the session open (once per sign-in is the extension's to count).
    func signedInPage(host: ShellHost)

    /// The app came back to the front.
    func becameActive(host: ShellHost)

    /// Signing out, while the site's session is still open: stop what works for this person and forget what is kept.
    func signOut() async

    /// Its rows in the native Settings, "On this phone" (an offline map's size).
    func settingsEntries(host: ShellHost) -> [ShellSettingsEntry]
}

/// One row an extension adds to Settings: a title, a value, and what a tap does (nil: nothing).
public struct ShellSettingsEntry {
    public var title: String
    public var detail: String?
    public var action: ((UIViewController) -> Void)?

    public init(title: String, detail: String? = nil, action: ((UIViewController) -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.action = action
    }
}

public extension ShellExtension {
    func bridgeMethods(host: ShellHost) -> [(String, NativeBridge.Method)] { [] }
    var requirements: ShellRequirements { ShellRequirements() }
    func attach(to session: AppSession) {}
    func configure(_ configuration: WKWebViewConfiguration) {}
    func nativeScreen(path: String, host: ShellHost) -> UIViewController? { nil }
    func notificationScreen(key: String, url: URL?, host: ShellHost) -> UIViewController? { nil }
    func signedInPage(host: ShellHost) {}
    func becameActive(host: ShellHost) {}
    func signOut() async {}
    func settingsEntries(host: ShellHost) -> [ShellSettingsEntry] { [] }
}

extension ShellRequirements {
    /// The keys [info] lacks, as `Info.plist` names them.
    func missing(in info: [String: Any]) -> [String] {
        var missing = purposeStrings.filter { (info[$0] as? String)?.isEmpty != false }
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        missing += backgroundModes.filter { !modes.contains($0) }.map { "UIBackgroundModes: \($0)" }
        let temporary = info["NSLocationTemporaryUsageDescriptionDictionary"] as? [String: String] ?? [:]
        missing += temporaryLocationPurposes.filter { temporary[$0]?.isEmpty != false }
            .map { "NSLocationTemporaryUsageDescriptionDictionary: \($0)" }
        return missing
    }
}
