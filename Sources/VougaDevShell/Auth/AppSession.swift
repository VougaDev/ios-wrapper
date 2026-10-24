import UIKit
import WebKit

/// The app's sign-in, one per process (the app keeps the instance): the Keychain's refresh token, the account service's endpoints, the
/// trade for the site's session and the one [SessionKeeper] every caller shares (the web view, tracking, later push).
/// An app subclasses it only to clear what its own features keep ([beforeSessionEnds], [afterSignOut]).
@MainActor
open class AppSession {

    public let config: ShellConfig
    public let origin: AppOrigin
    public let client: AuthClient
    public let store: TokenStore
    public let cookies: CookieJar
    public let endpoints: AuthEndpoints
    public private(set) lazy var keeper = SessionKeeper(
        store: store, refresher: endpoints, exchange: { [unowned self] in await self.exchange.open($0) }, cookies: cookies
    )
    private lazy var exchange = SessionExchange(origin: origin, userAgent: { [unowned self] in self.userAgent },
                                                acceptLanguage: Self.acceptLanguage, transport: AppHttp.transport)
    private let defaults: UserDefaults

    /// The mission tracking of this app, when its configuration turns it on.
    public private(set) lazy var tracking: TrackingService? = config.features.contains(.tracking)
        ? TrackingService(store: TrackingStore(defaults: defaults), disclosure: TrackingDisclosure(defaults: defaults), caller: { [unowned self] in self.caller() })
        : nil

    public init(config: ShellConfig) {
        self.config = config
        origin = AppOrigin(config.baseURL)
        client = AuthClient(issuer: config.authBaseURL, clientID: config.authClientID, redirectURI: config.redirectURI)
        store = TokenStore(vault: KeychainVault(service: config.storeName + ".auth"))
        cookies = WebCookies(origin: origin)
        defaults = UserDefaults(suiteName: config.storeName) ?? .standard
        let transport = AppHttp.transport
        let discoveryDefaults = defaults
        let issuer = config.authBaseURL
        endpoints = AuthEndpoints(client: client, transport: transport) {
            await Self.discovery(issuer: issuer, defaults: discoveryDefaults, transport: transport)
        }
    }

    /// The web view's own shape plus ` <Token>App/<version> (iOS)`, as every native call sends it.
    public var userAgent: String {
        AppHttp.userAgent(systemVersion: UIDevice.current.systemVersion, token: config.userAgentToken, version: config.versionName)
    }

    nonisolated static func acceptLanguage() -> String { AppHttp.acceptLanguage(AppHttp.phoneLanguages()) }

    /// A caller of the site's API as the web view's session, renewing it when lost.
    public func caller() -> AppCaller {
        AppCaller(origin: origin, cookies: { [cookies] in await cookies.jar() }, userAgent: { [userAgent] in userAgent },
                  acceptLanguage: Self.acceptLanguage, renew: { [keeper] in await keeper.renew(lostJar: $0) })
    }

    /// True when the person signed in on this phone (a refresh token is kept); the site's session may still need opening.
    public var signedIn: Bool { store.signedIn }

    public func discovery() async -> Discovery? {
        await Self.discovery(issuer: config.authBaseURL, defaults: defaults, transport: AppHttp.transport)
    }

    /// the account service's discovery document, kept on the phone for a day; the account service out of reach, the phone's copy serves. Nil only before
    /// a first successful read.
    nonisolated static func discovery(issuer: String, defaults: UserDefaults, transport: HttpTransport) async -> Discovery? {
        let kept = Discovery.parse(defaults.data(forKey: "discovery"))
        if let kept, Date().timeIntervalSince1970 - defaults.double(forKey: "discovery_at") < 24 * 3600 { return kept }
        guard let url = Discovery.url(issuer: issuer),
              let (data, response) = try? await transport.send(URLRequest(url: url)),
              response.statusCode == 200, Discovery.parse(data) != nil else { return kept }
        defaults.set(data, forKey: "discovery")
        defaults.set(Date().timeIntervalSince1970, forKey: "discovery_at")
        return Discovery.parse(data)
    }

    /// SIGNING OUT OF THIS APP ON THIS PHONE, never out of VougaDev (no end_session: the person's other applications stay
    /// signed in). In this order, while the site's session still exists: the app's own [beforeSessionEnds], the site's
    /// session ended; then the refresh token is revoked at the account service, and the tokens, the cookies and what the app keeps go.
    public func signOut() async {
        tracking?.stop()
        if let jar = await cookies.jar(), !jar.isEmpty {
            let fixed = jar
            await beforeSessionEnds(AppCaller(origin: origin, cookies: { fixed }, userAgent: { [userAgent] in userAgent },
                                              acceptLanguage: Self.acceptLanguage, renew: { _ in .signIn }))
            await endSiteSession(jar)
        }
        if let token = store.refreshToken() { await endpoints.revoke(token) }
        store.clear()
        await cookies.clear()
        tracking?.forget()
        await afterSignOut()
    }

    /// Called on sign-out while the site's session is still open; [caller] never renews it.
    open func beforeSessionEnds(_ caller: AppCaller) async {}

    /// Called on sign-out once the tokens and cookies are gone: what the app keeps of the person goes too.
    open func afterSignOut() async {}

    /// The web's own sign-out (`/auth/logout/`, POST with CSRF); its answer changes nothing on the phone.
    private func endSiteSession(_ jar: String) async {
        guard let url = URL(string: origin.baseURL + SignInRoute.siteSignOut),
              let headers = AppHttp.headers(origin: origin, cookies: jar, userAgent: userAgent, acceptLanguage: Self.acceptLanguage(), unsafe: true)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        _ = try? await AppHttp.transport.send(request)
    }
}

/// The web view's cookie store for the app's origin.
@MainActor
final class WebCookies: CookieJar {
    let origin: AppOrigin
    private var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    init(origin: AppOrigin) { self.origin = origin }

    func jar() async -> String? { Self.header(for: origin, from: await store.allCookies()) }

    func put(_ cookies: [HTTPCookie]) async {
        for cookie in cookies { await store.setCookie(cookie) }
    }

    func clear() async {
        for cookie in await store.allCookies() { await store.deleteCookie(cookie) }
    }

    /// The `Cookie` header the site gets: its host's cookies (a `.domain` one too), unexpired, secure ones on https only.
    nonisolated static func header(for origin: AppOrigin, from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let mine = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let hostMatches = origin.host == domain || origin.host.hasSuffix("." + domain)
            let alive = cookie.expiresDate.map { $0 > now } ?? true
            return hostMatches && alive && (!cookie.isSecure || origin.scheme == "https")
        }
        guard !mine.isEmpty else { return nil }
        return mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
