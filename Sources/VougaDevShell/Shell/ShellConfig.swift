import UIKit

/// The colours of the shell's own screens (sign-in, offline). Dynamic colours follow the system's dark mode.
public struct ShellColors {
    public var background: UIColor
    public var text: UIColor
    public var muted: UIColor
    public var accent: UIColor
    public var onAccent: UIColor

    public init(background: UIColor = .systemBackground, text: UIColor = .label, muted: UIColor = .secondaryLabel,
                accent: UIColor = .tintColor, onAccent: UIColor = .white) {
        self.background = background
        self.text = text
        self.muted = muted
        self.accent = accent
        self.onAccent = onAccent
    }
}

/// What makes the shell one app's (README.md). Written once by the app, in its own target.
///
/// - [baseURL]: the web app the web view shows, the only origin granted anything, e.g. `https://app.example.org`;
/// - [authBaseURL], [authClientID]: the account service and the app's own PUBLIC client (PKCE, no secret), never the web's;
/// - [redirectURI]: `<bundle id>:/oauth2redirect`, registered on that client;
/// - [userAgentToken]: ` <token>App/<version> (iOS)` ends the user agent, which the site reads (`Ship` for Ship);
/// - [storeName]: the name of what the app keeps on the phone; never changed once shipped, or people are signed out.
public struct ShellConfig {
    public var baseURL: String
    public var authBaseURL: String
    public var authClientID: String
    public var redirectURI: String
    public var userAgentToken: String
    public var versionName: String
    public var storeName: String
    public var colors: ShellColors
    /// The app's mark, over its name on the sign-in screen (144 points, as on the other platform); nil: the name alone.
    public var mark: UIImage?
    /// The app's own type for its name on the sign-in screen (scaled with Dynamic Type); nil: the system's, bold.
    public var titleFont: UIFont?
    public var scopes: String
    /// The account service's authorization endpoint and sign-in pages, as path prefixes: met in the web view, they run
    /// the native sign-in instead (its other pages open in Safari).
    public var authSignInPaths: [String]
    /// The site's privacy page: on the sign-in screen and in Settings, "Privacy and data" (App Review 5.1.1).
    public var privacyPath: String?
    /// The account service's page that deletes the account (App Review 5.1.1(v)), in Settings, "Privacy and data".
    public var accountDeletionURL: String?
    /// Push notifications through the hub; nil: none, and the permission is never asked.
    public var push: ShellPush.Settings?
    /// The purposes the site asks consent for; nil: no consent dialog.
    public var consent: ShellConsent.Settings?
    /// Debug builds' UI tests only: the app behaves as with no network (every call fails as in airplane mode), with
    /// the site's real addresses, so the pages kept on the phone are the ones it shows.
    public var simulateOffline = false
    /// Safari's Web Inspector may attach to the web view (debug builds only).
    public var inspectable: Bool

    /// `permissions` carries the app's grants; no `resource`: the token is traded at the site for a session.
    public static let defaultScopes = "openid profile email phone permissions"

    public init(baseURL: String, authBaseURL: String, authClientID: String, userAgentToken: String,
                colors: ShellColors = ShellColors(), mark: UIImage? = nil, titleFont: UIFont? = nil,
                redirectURI: String? = nil, storeName: String? = nil, versionName: String? = nil,
                scopes: String = ShellConfig.defaultScopes, authSignInPaths: [String] = [], privacyPath: String? = "/privacy/",
                accountDeletionURL: String? = nil, push: ShellPush.Settings? = nil, consent: ShellConsent.Settings? = nil,
                inspectable: Bool = false) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vougadev.app"
        self.baseURL = baseURL
        self.authBaseURL = authBaseURL
        self.authClientID = authClientID
        self.userAgentToken = userAgentToken
        self.colors = colors
        self.mark = mark
        self.titleFont = titleFont
        self.redirectURI = redirectURI ?? "\(bundleID):/oauth2redirect"
        self.storeName = storeName ?? bundleID
        self.versionName = versionName ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        self.scopes = scopes
        self.privacyPath = privacyPath
        self.authSignInPaths = authSignInPaths
        self.accountDeletionURL = accountDeletionURL
        self.push = push
        self.consent = consent
        self.inspectable = inspectable
    }
}

/// The shell's and its extensions' texts in the phone's language (en, fr, es). An app rewords any of them in its own
/// `Shell.strings` (the sign-in sentence, the notifications sentence), which is read first.
public enum ShellStrings {
    public static func text(_ key: String, bundle: Bundle) -> String {
        let fallback = NSLocalizedString(key, bundle: bundle, comment: "")
        return NSLocalizedString(key, tableName: "Shell", bundle: .main, value: fallback, comment: "")
    }

    public static func appName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    }
}

/// The core's own texts.
enum Strings {
    static func text(_ key: String) -> String { ShellStrings.text(key, bundle: .module) }
    static func appName() -> String { ShellStrings.appName() }
}

/// The core's resource bundle (its texts), for tests and tools.
public enum ShellResources {
    public static let bundle = Bundle.module
}
