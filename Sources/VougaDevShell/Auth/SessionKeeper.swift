import Foundation

/// What a renewal came to.
public enum Renewal: Equatable {
    /// The site's session is open again (cookies in the web view's store): retry what failed.
    case renewed
    /// The account service refused the refresh, or there was no token: the native sign-in screen.
    case signIn
    /// The account service or the site out of reach: nothing was forgotten, try again later.
    case offline
}

/// The web view's cookies for the site's origin, as the keeper needs them.
@MainActor
public protocol CookieJar: AnyObject {
    /// The `Cookie` header text the web view sends the site (`a=1; sessionid=...`), or nil.
    func jar() async -> String?
    func put(_ cookies: [HTTPCookie]) async
    func clear() async
}

/// What `POST /auth/app-session/` answered.
public enum Exchange {
    /// 204: the site's cookies (`sessionid`, `csrftoken`), for the web view's store.
    case opened([HTTPCookie])
    /// 401: the site did not accept the token (expired, another client's, or the account service could not say who it is).
    case refused
    case offline
    case failed(status: Int)
}

/// THE APP'S the account service ACCESS TOKEN TRADED FOR THE SITE'S SESSION: a POST with `Authorization: Bearer <token>` and no
/// cookie, answered 204 with the session's cookies. Those go into the web view's store, and the web view and the native
/// calls are signed in as that person.
public struct SessionExchange {
    public static let path = "/auth/app-session/"

    let origin: AppOrigin
    let userAgent: () -> String
    let acceptLanguage: () -> String
    let transport: HttpTransport

    public func open(_ accessToken: String) async -> Exchange {
        guard let (_, response) = try? await transport.send(Self.request(origin, accessToken, userAgent(), acceptLanguage())) else {
            return .offline
        }
        return Self.read(response)
    }

    /// No cookie (a bearer token is the whole proof, the view is CSRF-exempt), the site's Referer as on every call.
    static func request(_ origin: AppOrigin, _ accessToken: String, _ userAgent: String, _ acceptLanguage: String) -> URLRequest {
        var request = URLRequest(url: URL(string: origin.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(origin.baseURL + "/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// A session only when the answer carries `sessionid`: a 204 without it opened nothing.
    static func read(_ response: HTTPURLResponse) -> Exchange {
        let status = response.statusCode
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { all, field in
            if let name = field.key as? String, let value = field.value as? String { all[name] = value }
        }
        let cookies = response.url.map { HTTPCookie.cookies(withResponseHeaderFields: fields, for: $0) } ?? []
        if (200...299).contains(status) && cookies.contains(where: { $0.name == SessionCookies.session && !$0.value.isEmpty }) {
            return .opened(cookies)
        }
        if status == 401 || status == 403 { return .refused }
        return .failed(status: status)
    }
}

/// A LOST SESSION IS RENEWED SILENTLY: the refresh token (rotated, stored at once), then a new site session for the
/// fresh access token. Only a refused refresh asks the person to sign in again.
///
/// One renewal at a time for the whole app (the web view and every native call): the account service spends a refresh token on first
/// use, so two concurrent refreshes would sign the person out. A caller that waited while another renewed sees the
/// session cookie changed and does not refresh again.
@MainActor
public final class SessionKeeper {
    let store: TokenStore
    let refresher: Refresher
    let exchange: (String) async -> Exchange
    let cookies: CookieJar
    private var tail: Task<Void, Never>?

    public init(store: TokenStore, refresher: Refresher, exchange: @escaping (String) async -> Exchange, cookies: CookieJar) {
        self.store = store
        self.refresher = refresher
        self.exchange = exchange
        self.cookies = cookies
    }

    /// [lostJar] is the cookie text the failed call was made with (nil: none was).
    public func renew(lostJar: String?) async -> Renewal {
        await serially { await self.renewLocked(lostJar) }
    }

    /// The browser sign-in's tokens: kept, then traded for the site's session.
    public func signedIn(accessToken: String, refreshToken: String?) async -> Renewal {
        await serially {
            self.store.save(refreshToken)
            return await self.open(accessToken)
        }
    }

    /// Runs [work] after every earlier one finished. An unstructured task: NOT CANCELLED HALF-WAY, since once the account service
    /// rotated the token the new one must reach the store or the person is out.
    private func serially(_ work: @escaping @MainActor () async -> Renewal) async -> Renewal {
        let previous = tail
        let task = Task { @MainActor () -> Renewal in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func renewLocked(_ lostJar: String?) async -> Renewal {
        let lost = SessionCookies.value(in: lostJar, named: SessionCookies.session)
        let now = SessionCookies.value(in: await cookies.jar(), named: SessionCookies.session)
        if let now, now != lost { return .renewed }
        guard let refreshToken = store.refreshToken() else { return .signIn }
        let answer = await refresher.refresh(refreshToken)
        switch answer {
        case .refused:
            store.clear()
            return .signIn
        case .unreachable:
            return .offline
        case let .tokens(access, refresh):
            store.save(refresh)
            return await open(access)
        }
    }

    private func open(_ accessToken: String) async -> Renewal {
        switch await exchange(accessToken) {
        case let .opened(set):
            await cookies.put(set)
            return .renewed
        // The site out of reach or failing (an edge's 502): later, nothing forgotten
        case .offline: return .offline
        case let .failed(status): return status >= 500 ? .offline : .signIn
        // The site refused a token the account service just gave: the browser sign-in starts over (it replaces the tokens)
        case .refused: return .signIn
        }
    }
}
