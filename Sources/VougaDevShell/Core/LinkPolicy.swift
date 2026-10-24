import Foundation

/// Where a top-level navigation goes. The web view shows the site and nothing else: SIGN-IN NEVER HAPPENS IN IT (The account service's
/// rule: Google and passkeys refuse a web view, RFC 8252), so the site's `/auth/login/` and the account service's sign-in pages run the
/// app's own sign-in instead ([SignInRoute]); the account service's other pages (the account) open in Safari, where the VougaDev session
/// lives. A person who taps an address, a phone number or a map link gets the app that handles it.
public enum LinkPolicy {

    public enum Decision: Equatable {
        /// A page of the site: load it in the web view.
        case loadInside
        /// A path the app shows natively (its `ShellViewController.nativeScreen`): that screen opens instead.
        case openNative
        /// The site's or the account service's sign-in: the session is renewed, or the native sign-in screen shown.
        case signIn
        /// Another web host (The account service's account pages too), `tel:`, `mailto:`, a maps or chat app: handed to the system.
        case openOutside
        /// An `intent:` URL. The shared table names it; on this platform it is never followed.
        case openIntent
        /// Schemes that would read local data or run script: never followed.
        case block
    }

    static let blocked: Set<String> = ["file", "content", "javascript", "data", "blob", "about", "chrome", "android-app"]

    /// [path] is the URL's path (no query); it decides between the site's pages and sign-in. [authSignInPaths] are the
    /// account service's sign-in pages (`ShellConfig.authSignInPaths`).
    public static func decide(scheme: String?, isSite: Bool, isAuth: Bool, isNativeRoute: Bool, path: String? = nil,
                              authSignInPaths: [String] = []) -> Decision {
        guard let s = scheme?.lowercased() else { return .block }
        if isSite && SignInRoute.isSiteSignIn(path) { return .signIn }
        if isAuth && SignInRoute.isAuthSignIn(path, paths: authSignInPaths) { return .signIn }
        if isSite && isNativeRoute { return .openNative }
        if isSite { return .loadInside }
        if s == "intent" { return .openIntent }
        if blocked.contains(s) { return .block }
        return .openOutside
    }
}

/// The site's and the account service's sign-in and sign-out addresses, as the shell meets them in the web view.
///
/// - the site's `/auth/login/?next=<path>`, where a lost session is sent;
/// - the account service's authorization endpoint and sign-in pages, which each app names (`ShellConfig.authSignInPaths`);
/// - the site's sign-out: the web's form POSTs `/auth/logout/`.
public enum SignInRoute {
    public static let siteSignIn = "/auth/login/"
    public static let siteSignOut = "/auth/logout/"

    public static func isSiteSignIn(_ path: String?) -> Bool { path == siteSignIn || path == String(siteSignIn.dropLast()) }

    public static func isAuthSignIn(_ path: String?, paths: [String]) -> Bool {
        guard let path else { return false }
        return paths.contains { path.hasPrefix($0) }
    }

    /// The web's sign-out form: a top-level POST to the site's `/auth/logout/`.
    public static func isSignOut(method: String?, isSite: Bool, path: String?) -> Bool {
        isSite && method?.uppercased() == "POST" && (path == siteSignOut || path == String(siteSignOut.dropLast()))
    }

    /// Where to go once signed in: the sign-in's `next` when it is a page of the site's own (never the sign-in or
    /// sign-out again), else the site's home. [next] is the decoded query value.
    public static func after(_ origin: AppOrigin, next: String?) -> String {
        let url = origin.pageURL(next?.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url, let next else { return origin.baseURL + "/" }
        let path = next.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? next
        return path.hasPrefix("/auth/") ? origin.baseURL + "/" : url
    }
}
