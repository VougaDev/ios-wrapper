import Foundation

/// Where a top-level navigation goes: one app, one web view. The site, the company's other domains and subdomains and the
/// account service's own pages all load in the same web view; only an outside company's site opens in an in-app sheet,
/// and a phone number, an address or a chat link in the phone's app for it. The sign-in runs in the web view or, until the
/// account service finishes it through the bridge, in the system sign-in sheet ([SignInRoute]).
public enum LinkPolicy {

    public enum Decision: Equatable {
        /// A page of the site: load it in the web view.
        case loadInside
        /// A path the app shows natively (its `ShellViewController.nativeScreen`): that screen opens instead.
        case openNative
        /// The site's or the account service's sign-in: the session is renewed, or the native sign-in screen shown.
        case signIn
        /// An outside company's site (a map, a bank's confirmation): an in-app sheet (`SFSafariViewController`), back by itself.
        case openSheet
        /// `tel:`, `mailto:`, a maps or chat app: the phone's own app.
        case openOutside
        /// An `intent:` URL. The shared table names it; on this platform it is never followed.
        case openIntent
        /// Schemes that would read local data or run script: never followed.
        case block
    }

    static let blocked: Set<String> = ["file", "content", "javascript", "data", "blob", "about", "chrome", "android-app"]

    /// ONE APP, ONE WEB VIEW: the site, the company's other domains and the account service load inside; only an outside
    /// company's site goes to a sheet, and the phone's own schemes to its apps. [path] is the URL's path (no query).
    /// [authSignInPaths] are the account service's sign-in pages: they run in the web view when [signInInWebView], else
    /// the system sheet.
    public static func decide(scheme: String?, isSite: Bool, isAuth: Bool, isCompany: Bool = false, isNativeRoute: Bool,
                              path: String? = nil, authSignInPaths: [String] = [], signInInWebView: Bool = false,
                              isAppLink: Bool = false) -> Decision {
        guard let s = scheme?.lowercased() else { return .block }
        // A link an app on the phone answers (Telegram's t.me): that app, tapped or redirected to, never the web view.
        if isAppLink && (s == "https" || s == "http") { return .openOutside }
        if isSite && SignInRoute.isSiteSignIn(path) { return .signIn }
        if isAuth && SignInRoute.isAuthSignIn(path, paths: authSignInPaths) { return signInInWebView ? .loadInside : .signIn }
        if isSite && isNativeRoute { return .openNative }
        if isSite || isAuth || (isCompany && (s == "https" || s == "http")) { return .loadInside }
        if s == "intent" { return .openIntent }
        if blocked.contains(s) { return .block }
        if s == "https" || s == "http" { return .openSheet }
        return .openOutside
    }

    /// Hosts whose links belong to an app on the phone: Telegram's bot and chat links.
    public static let appHosts = ["t.me", "telegram.me"]

    /// True for [host] on one of the company's [domains] or their subdomains (`pay.example.org` for `example.org`).
    public static func isCompany(host: String?, domains: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return domains.contains { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }
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

    /// What a site's `/auth/login/?…` asks of the account service: a sign-up (`prompt=create`), a fresh sign-in
    /// (`prompt=login`), the account chooser (`prompt=select_account`), a recent one (`max_age`); empty for a plain
    /// sign-in, which renews silently.
    public static func asks(_ items: [URLQueryItem]) -> [String: String] {
        var asks: [String: String] = [:]
        if let prompt = items.first(where: { $0.name == "prompt" })?.value, ["create", "login", "select_account"].contains(prompt) {
            asks["prompt"] = prompt
        }
        if let age = items.first(where: { $0.name == "max_age" })?.value, let seconds = Int(age), seconds >= 0 { asks["max_age"] = String(seconds) }
        return asks
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
