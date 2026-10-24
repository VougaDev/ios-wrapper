import XCTest
@testable import VougaDevShell

final class NetTests: XCTestCase {

    func testHeadersCarryTheSessionAndCSRFOnUnsafeCalls() {
        let jar = "a=1; csrftoken=tok; sessionid=s1"
        let get = AppHttp.headers(origin: origin, cookies: jar, userAgent: "UA", acceptLanguage: "fr", unsafe: false)!
        XCTAssertEqual(get["Cookie"], jar)
        XCTAssertEqual(get["Referer"], "https://app.example.org/")
        XCTAssertNil(get["X-CSRFToken"])
        XCTAssertEqual(AppHttp.headers(origin: origin, cookies: jar, userAgent: "UA", acceptLanguage: "fr", unsafe: true)?["X-CSRFToken"], "tok")
        XCTAssertNil(AppHttp.headers(origin: origin, cookies: "sessionid=s1", userAgent: "UA", acceptLanguage: "fr", unsafe: true))
    }

    func testUserAgentAndLanguages() {
        XCTAssertEqual(AppHttp.userAgentSuffix(token: "Ship", version: "1.0.12"), " ShipApp/1.0.12 (iOS)")
        XCTAssertTrue(AppHttp.userAgent(systemVersion: "18.0", token: "Ship", version: "1.0.0")
            .hasSuffix("iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 ShipApp/1.0.0 (iOS)"))
        XCTAssertEqual(AppHttp.acceptLanguage(["fr-FR", "fr", "en"]), "fr-FR,fr;q=0.9,en;q=0.8")
        XCTAssertEqual(AppHttp.acceptLanguage([]), "en")
        XCTAssertEqual(String(decoding: AppHttp.form([("a b", "x+y/z"), ("k", "é")]), as: UTF8.self), "a%20b=x%2By%2Fz&k=%C3%A9")
    }

    func testCookies() {
        XCTAssertEqual(SessionCookies.value(in: "a=1; sessionid=xyz; csrftoken=", named: "sessionid"), "xyz")
        XCTAssertNil(SessionCookies.value(in: "a=1; csrftoken=", named: "csrftoken"))
        XCTAssertFalse(SessionCookies.isSignedIn(nil))
        let now = Date()
        let cookie = { (name: String, domain: String, secure: Bool, expires: Date?) in
            HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/", .secure: secure ? "TRUE" : "FALSE",
                                    .expires: expires ?? now.addingTimeInterval(3600)])!
        }
        let header = WebCookies.header(for: origin, from: [
            cookie("sessionid", "app.example.org", true, nil),
            cookie("wide", ".example.org", false, nil),
            cookie("other", "evil.io", false, nil),
            cookie("old", "app.example.org", false, now.addingTimeInterval(-10)),
        ], now: now)
        XCTAssertEqual(header, "sessionid=v; wide=v")
    }

    func testApiOutcome() {
        func classify(_ status: Int, _ body: String) -> ApiOutcome { ApiOutcome.classify(status: status, body: Data(body.utf8)) }
        guard case .ok = classify(200, #"{"a":1}"#) else { return XCTFail() }
        guard case .sessionLost = classify(302, "") else { return XCTFail() }
        guard case .sessionLost = classify(401, #"{"code":"unauthenticated"}"#) else { return XCTFail() }
        guard case .sessionLost = classify(403, "<html>CSRF</html>") else { return XCTFail() }
        guard case let .refused(status, code, detail) = classify(400, #"{"code":"not_started","detail":"Pas encore."}"#) else { return XCTFail() }
        XCTAssertEqual([String(status), code, detail], ["400", "not_started", "Pas encore."])
        guard case .failed(502) = classify(502, "<html>Bad gateway</html>") else { return XCTFail() }
        guard case .failed(200) = classify(200, "[1]") else { return XCTFail() }
    }

    @MainActor
    func testCallerRenewsALostSessionOnceThenRetries() async {
        var jar = "csrftoken=t; sessionid=old"
        var renewals = 0
        let transport = FakeTransport { request in
            request.value(forHTTPHeaderField: "Cookie")!.contains("sessionid=old") ? (302, ["Location": "/auth/login/"], "") : (200, [:], #"{"ok":true}"#)
        }
        let caller = AppCaller(origin: origin, cookies: { jar }, userAgent: { "UA" }, acceptLanguage: { "en" },
                               renew: { _ in renewals += 1; jar = "csrftoken=t; sessionid=new"; return .renewed }, transport: transport)
        guard case .ok = await caller.postJSON("/api/v1/x", ["a": 1]) else { return XCTFail() }
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual(transport.sent[1].value(forHTTPHeaderField: "X-CSRFToken"), "t")
        XCTAssertEqual(transport.sent[1].value(forHTTPHeaderField: "Content-Type"), "application/json")

        let refused = AppCaller(origin: origin, cookies: { "csrftoken=t; sessionid=old" }, userAgent: { "UA" }, acceptLanguage: { "en" },
                                renew: { _ in .signIn }, transport: transport)
        let lost = await refused.get("/api/v1/x")
        XCTAssertTrue(lost.isSessionLost)
        let offline = AppCaller(origin: origin, cookies: { nil }, userAgent: { "UA" }, acceptLanguage: { "en" },
                                renew: { _ in .offline }, transport: transport)
        guard case .offline = await offline.get("/api/v1/x") else { return XCTFail() }
    }
}

final class AuthTests: XCTestCase {

    let client = AuthClient(issuer: "https://auth.example.org", clientID: "test-client", redirectURI: "org.example.app:/oauth2redirect")

    func testPKCEMatchesRFC7636() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.verifier().count, 43)
        XCTAssertNotEqual(PKCE.verifier(), PKCE.verifier())
        XCTAssertEqual(client.callbackScheme, "org.example.app")
    }

    func testDiscoveryNeedsHTTPSEndpoints() {
        let good = #"{"issuer":"https://auth.example.org","authorization_endpoint":"https://auth.example.org/identity/o/authorize/","token_endpoint":"https://auth.example.org/identity/o/token/"}"#
        XCTAssertEqual(Discovery.parse(Data(good.utf8))?.tokenEndpoint, "https://auth.example.org/identity/o/token/")
        XCTAssertNil(Discovery.parse(Data(good.replacingOccurrences(of: "https://auth.example.org/identity/o/token/", with: "http://x/").utf8)))
        XCTAssertNil(Discovery.parse(Data("nope".utf8)))
        XCTAssertEqual(Discovery.url(issuer: "https://auth.example.org/")?.absoluteString, "https://auth.example.org/.well-known/openid-configuration")
    }

    func testAuthorizeURLAndCallback() {
        let discovery = Discovery(json: ["authorization_endpoint": "https://auth.example.org/identity/o/authorize/"])
        let request = AuthorizeRequest(state: "st", nonce: "no", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = request.url(discovery: discovery, client: client, scopes: "openid profile", uiLocales: "fr")!
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "test-client")
        XCTAssertEqual(items["redirect_uri"], "org.example.app:/oauth2redirect")
        XCTAssertEqual(items["scope"], "openid profile")
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["ui_locales"], "fr")
        XCTAssertEqual(request.read(callback: URL(string: "org.example.app:/oauth2redirect?code=c1&state=st"), client: client), .code("c1"))
        XCTAssertEqual(request.read(callback: URL(string: "org.example.app:/oauth2redirect?code=c1&state=other"), client: client), .failed)
        XCTAssertEqual(request.read(callback: URL(string: "org.example.app:/oauth2redirect?error=access_denied&state=st"), client: client), .failed)
        XCTAssertEqual(request.read(callback: URL(string: "evil:/oauth2redirect?code=c1&state=st"), client: client), .failed)
    }

    func testTokenAnswers() {
        XCTAssertEqual(TokenAnswer.read(status: 200, body: Data(#"{"access_token":"a","refresh_token":"r"}"#.utf8)), .tokens(access: "a", refresh: "r"))
        XCTAssertEqual(TokenAnswer.read(status: 200, body: Data(#"{"access_token":"a","refresh_token":""}"#.utf8)), .tokens(access: "a", refresh: nil))
        XCTAssertEqual(TokenAnswer.read(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)), .refused)
        XCTAssertEqual(TokenAnswer.read(status: 503, body: nil), .unreachable)
    }

    func testEndpointsPostForms() async {
        let transport = FakeTransport { _ in (200, [:], #"{"access_token":"a2","refresh_token":"r2"}"#) }
        let discovery = Discovery(json: ["token_endpoint": "https://auth.example.org/token/", "revocation_endpoint": "https://auth.example.org/revoke/"])
        let endpoints = AuthEndpoints(client: client, transport: transport) { discovery }
        let answer = await endpoints.exchange(code: "c1", verifier: "v1")
        XCTAssertEqual(answer, .tokens(access: "a2", refresh: "r2"))
        let body = String(decoding: transport.sent[0].httpBody!, as: UTF8.self)
        XCTAssertEqual(body, "grant_type=authorization_code&code=c1&redirect_uri=org.example.app%3A%2Foauth2redirect&client_id=test-client&code_verifier=v1")
        await endpoints.revoke("r2")
        XCTAssertEqual(transport.sent[1].url?.absoluteString, "https://auth.example.org/revoke/")
        let offline = AuthEndpoints(client: client, transport: transport) { nil }
        let none = await offline.refresh("r")
        XCTAssertEqual(none, .unreachable)
    }

    func testTokenStoreKeepsTheTokenWhenNoneIsRotated() {
        let store = TokenStore(vault: MemoryVault())
        XCTAssertFalse(store.signedIn)
        store.save("r1")
        store.save(nil)
        store.save(" ")
        XCTAssertEqual(store.refreshToken(), "r1")
        store.clear()
        XCTAssertNil(store.refreshToken())
    }

    func testExchangeNeedsASessionCookie() {
        let url = URL(string: "https://app.example.org/auth/app-session/")!
        let opened = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil,
                                     headerFields: ["Set-Cookie": "sessionid=s9; Path=/; Secure; HttpOnly, csrftoken=c9; Path=/"])!
        guard case let .opened(cookies) = SessionExchange.read(opened) else { return XCTFail() }
        XCTAssertEqual(Set(cookies.map(\.name)), ["sessionid", "csrftoken"])
        guard case .failed(204) = SessionExchange.read(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: [:])!) else { return XCTFail() }
        guard case .refused = SessionExchange.read(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: [:])!) else { return XCTFail() }
        let request = SessionExchange.request(origin, "tok", "UA", "fr")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    private let opened: (String) async -> Exchange = { _ in
        .opened([HTTPCookie(properties: [.name: "sessionid", .value: "new", .domain: "app.example.org", .path: "/"])!])
    }

    @MainActor
    func testKeeperRenewsWithTheRotatedToken() async {
        let store = TokenStore(vault: MemoryVault("r1"))
        let refresher = FakeRefresher([.tokens(access: "a", refresh: "r2")])
        let jar = MemoryJar("sessionid=old")
        let keeper = SessionKeeper(store: store, refresher: refresher, exchange: opened, cookies: jar)
        let renewal = await keeper.renew(lostJar: "sessionid=old")
        XCTAssertEqual(renewal, .renewed)
        XCTAssertEqual(store.refreshToken(), "r2")
        XCTAssertEqual(jar.text, "sessionid=new")
    }

    @MainActor
    func testConcurrentRenewalsRefreshOnce() async {
        let refresher = FakeRefresher([.tokens(access: "a", refresh: "r2"), .refused])
        let keeper = SessionKeeper(store: TokenStore(vault: MemoryVault("r1")), refresher: refresher, exchange: opened, cookies: MemoryJar("sessionid=old"))
        async let first = keeper.renew(lostJar: "sessionid=old")
        async let second = keeper.renew(lostJar: "sessionid=old")
        let both = await [first, second]
        XCTAssertEqual(both, [.renewed, .renewed])
        XCTAssertEqual(refresher.asked, ["r1"])
    }

    @MainActor
    func testKeeperOutcomes() async {
        let refused = TokenStore(vault: MemoryVault("r1"))
        let signIn = await SessionKeeper(store: refused, refresher: FakeRefresher([.refused]), exchange: opened, cookies: MemoryJar()).renew(lostJar: nil)
        XCTAssertEqual(signIn, .signIn)
        XCTAssertNil(refused.refreshToken(), "a refused token is forgotten")

        let kept = TokenStore(vault: MemoryVault("r1"))
        let offline = await SessionKeeper(store: kept, refresher: FakeRefresher([.unreachable]), exchange: opened, cookies: MemoryJar()).renew(lostJar: nil)
        XCTAssertEqual(offline, .offline)
        XCTAssertEqual(kept.refreshToken(), "r1", "nothing is forgotten offline")

        let none = await SessionKeeper(store: TokenStore(vault: MemoryVault()), refresher: FakeRefresher([]), exchange: opened, cookies: MemoryJar()).renew(lostJar: nil)
        XCTAssertEqual(none, .signIn)

        let edge = await SessionKeeper(store: TokenStore(vault: MemoryVault("r1")), refresher: FakeRefresher([.tokens(access: "a", refresh: nil)]),
                                       exchange: { _ in .failed(status: 502) }, cookies: MemoryJar()).renew(lostJar: nil)
        XCTAssertEqual(edge, .offline)
    }
}
