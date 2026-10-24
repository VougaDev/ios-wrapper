import UIKit

/// The native features an app turns on. Each adds its members to `window.VougaDevNative`, in the contract's order.
public enum ShellFeature: String, CaseIterable, Sendable {
    /// `startTracking`, `stopTracking`, `trackingState`: the mission's position shared in the background, with the
    /// disclosure first. Needs `UIBackgroundModes = [location]` and the location purpose strings.
    case tracking
    /// `openMissions`: the missions' pages, on the app's native screen when it has one ([ShellViewController.nativeScreen]).
    case missions
}

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
    public var features: Set<ShellFeature>
    public var colors: ShellColors
    public var scopes: String
    /// The account service's authorization endpoint and sign-in pages, as path prefixes: met in the web view, they run
    /// the native sign-in instead (its other pages open in Safari).
    public var authSignInPaths: [String]
    /// The site's privacy page, linked from the sign-in screen (App Review 5.1.1); nil shows no link.
    public var privacyPath: String?
    /// Safari's Web Inspector may attach to the web view (debug builds only).
    public var inspectable: Bool

    /// `permissions` carries the app's grants; no `resource`: the token is traded at the site for a session.
    public static let defaultScopes = "openid profile email phone permissions"

    public init(baseURL: String, authBaseURL: String, authClientID: String, userAgentToken: String,
                features: Set<ShellFeature> = [], colors: ShellColors = ShellColors(),
                redirectURI: String? = nil, storeName: String? = nil, versionName: String? = nil,
                scopes: String = ShellConfig.defaultScopes, authSignInPaths: [String] = [], privacyPath: String? = "/privacy/", inspectable: Bool = false) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.vougadev.app"
        self.baseURL = baseURL
        self.authBaseURL = authBaseURL
        self.authClientID = authClientID
        self.userAgentToken = userAgentToken
        self.features = features
        self.colors = colors
        self.redirectURI = redirectURI ?? "\(bundleID):/oauth2redirect"
        self.storeName = storeName ?? bundleID
        self.versionName = versionName ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        self.scopes = scopes
        self.privacyPath = privacyPath
        self.authSignInPaths = authSignInPaths
        self.inspectable = inspectable
    }
}

/// The shell's texts in the phone's language (en, fr, es). An app rewords any of them in its own `Shell.strings`
/// (the sign-in sentence, above all), which is read first.
enum Strings {
    static func text(_ key: String) -> String {
        let fallback = NSLocalizedString(key, bundle: .module, comment: "")
        return NSLocalizedString(key, tableName: "Shell", bundle: .main, value: fallback, comment: "")
    }

    static func appName() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    }
}
