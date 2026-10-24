import Foundation

/// One HTTP exchange; URLSession in the app, a fake in the tests.
public protocol HttpTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Calls the app makes to its site outside the web view, AS THE WEB VIEW'S SESSION. One session and one header set, so
/// every such call looks the same to the site:
///
/// - `Cookie`: the web view's cookies for the site's origin;
/// - `Referer`: the site's own origin - without it the site's CSRF check refuses an HTTPS POST (403 HTML);
/// - `Accept-Language`: the phone's languages - without it the server answers in its default, not the screen's;
/// - `X-CSRFToken`: the `csrftoken` cookie, on every unsafe method;
/// - `Accept: application/json` and the web view's user agent, ending ` <Token>App/<version> (iOS)`.
public enum AppHttp {

    /// No cookie store (the web view's is the only one) and no redirects of any kind: a 302 to the sign-in page IS the
    /// answer ("session lost"), and following it would turn it into a 200 HTML page that looks like success.
    public static let transport: HttpTransport = SessionTransport()

    /// ` ShipApp/1.0.12 (iOS)` for [token] `Ship`: the site tells the app, and its platform, from it.
    public static func userAgentSuffix(token: String, version: String) -> String { " \(token)App/\(version) (iOS)" }

    /// What WebKit appends to its own user agent: Safari's `Mobile/15E148`, kept so pages still see a phone, then the suffix.
    public static func applicationName(token: String, version: String) -> String {
        "Mobile/15E148" + userAgentSuffix(token: token, version: version)
    }

    /// The user agent native calls send, the web view's own shape for this system version.
    public static func userAgent(systemVersion: String, token: String, version: String) -> String {
        let os = systemVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + applicationName(token: token, version: version)
    }

    /// The headers of one call. [unsafe] is a POST (or any method that changes something): it carries `X-CSRFToken`,
    /// and nil is returned when the cookies hold no `csrftoken` - the call cannot pass the site's CSRF check, so it is not made.
    public static func headers(origin: AppOrigin, cookies: String, userAgent: String, acceptLanguage: String, unsafe: Bool) -> [String: String]? {
        var headers = [
            "Cookie": cookies,
            "Referer": origin.baseURL + "/",
            "Accept": "application/json",
            "Accept-Language": acceptLanguage,
            "User-Agent": userAgent,
        ]
        if unsafe {
            guard let csrf = SessionCookies.value(in: cookies, named: SessionCookies.csrf) else { return nil }
            headers["X-CSRFToken"] = csrf
        }
        return headers
    }

    /// `fr-FR,fr;q=0.9,en;q=0.8` from the phone's language list, first preferred.
    public static func acceptLanguage(_ tags: [String]) -> String {
        let list = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (list.isEmpty ? ["en"] : list).enumerated().map { i, tag in
            i == 0 ? tag : "\(tag);q=" + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), max(0.1, 1.0 - Double(i) * 0.1))
        }.joined(separator: ",")
    }

    public static func phoneLanguages() -> [String] { Locale.preferredLanguages }

    /// A form body, `application/x-www-form-urlencoded`, as OAuth's endpoints take it.
    static func form(_ fields: [(String, String)]) -> Data {
        // RFC 3986's unreserved characters, ASCII only (CharacterSet.alphanumerics holds every script's letters).
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&").utf8)
    }
}

/// Reading the `Cookie` header text: `a=1; csrftoken=xyz; sessionid=...`.
public enum SessionCookies {
    public static let csrf = "csrftoken"
    public static let session = "sessionid"

    public static func value(in cookies: String?, named name: String) -> String? {
        for part in (cookies ?? "").split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "="), pair[..<eq] == name else { continue }
            let value = String(pair[pair.index(after: eq)...])
            return value.isEmpty ? nil : value
        }
        return nil
    }

    public static func isSignedIn(_ cookies: String?) -> Bool { value(in: cookies, named: session) != nil }
}

final class SessionTransport: HttpTransport, @unchecked Sendable {

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        // A handover uploads one photo per package: up to twenty on a slow road.
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
