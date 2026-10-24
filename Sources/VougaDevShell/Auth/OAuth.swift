import CryptoKit
import Foundation

/// The app's the account service client: public (no secret), PKCE S256, its redirect a scheme of the app's own bundle id.
public struct AuthClient: Sendable {
    public let issuer: String
    public let clientID: String
    public let redirectURI: String

    /// `com.vougadev.ship` for `com.vougadev.ship:/oauth2redirect`: what `ASWebAuthenticationSession` waits for.
    public var callbackScheme: String { String(redirectURI.prefix { $0 != ":" }) }
}

/// What the account service's `/.well-known/openid-configuration` names; kept on the phone so a refresh costs one request.
public struct Discovery {
    public let json: JSONObject
    public var authorizationEndpoint: String { json["authorization_endpoint"] as? String ?? "" }
    public var tokenEndpoint: String { json["token_endpoint"] as? String ?? "" }
    public var revocationEndpoint: String? { (json["revocation_endpoint"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    public static func url(issuer: String) -> URL? {
        var base = issuer
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/.well-known/openid-configuration")
    }

    /// Nil unless it names at least the endpoints the app calls, on https.
    public static func parse(_ data: Data?) -> Discovery? {
        guard let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return nil }
        let names = ["issuer", "authorization_endpoint", "token_endpoint"]
        return names.allSatisfy({ (json[$0] as? String)?.hasPrefix("https://") == true }) ? Discovery(json: json) : nil
    }
}

/// RFC 7636: the verifier stays on the phone, the account service sees only its SHA-256.
public enum PKCE {
    /// 32 random bytes, base64url: 43 characters.
    public static func verifier() -> String { randomToken() }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No random bytes")
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One browser sign-in: the authorization URL and what the redirect brought back.
public struct AuthorizeRequest {
    public let state: String
    public let nonce: String
    public let verifier: String

    public init(state: String = PKCE.randomToken(), nonce: String = PKCE.randomToken(), verifier: String = PKCE.verifier()) {
        self.state = state
        self.nonce = nonce
        self.verifier = verifier
    }

    /// the account service's pages in the phone's language ([uiLocales]), as the web's own sign-in asks.
    public func url(discovery: Discovery, client: AuthClient, scopes: String, uiLocales: String) -> URL? {
        guard var parts = URLComponents(string: discovery.authorizationEndpoint) else { return nil }
        parts.queryItems = (parts.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "ui_locales", value: uiLocales),
        ]
        // `+` is a space to a form decoder: a scope list must not turn into one.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    public enum Callback: Equatable {
        case code(String)
        /// the account service answered an error, or a redirect that is not this sign-in's (another state): nothing is trusted.
        case failed
    }

    public func read(callback: URL?, client: AuthClient) -> Callback {
        guard let callback, callback.absoluteString.hasPrefix(client.redirectURI),
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else { return .failed }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("error") == nil, value("state") == state, let code = value("code"), !code.isEmpty else { return .failed }
        return .code(code)
    }
}

/// One token endpoint answer.
public enum TokenAnswer: Equatable {
    case tokens(access: String, refresh: String?)
    /// the account service said no (`invalid_grant`: revoked, expired or already spent): the person signs in again.
    case refused
    /// No network, or the account service out of reach: the token is kept for the next try.
    case unreachable

    /// 200 with an access token; 400 or 401 (`invalid_grant`, `invalid_client`) refuses; anything else is unreachable.
    public static func read(status: Int, body: Data?) -> TokenAnswer {
        let json = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSONObject }
        let access = json?["access_token"] as? String ?? ""
        if status == 200 && !access.isEmpty {
            let refresh = (json?["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .tokens(access: access, refresh: refresh)
        }
        return status == 400 || status == 401 ? .refused : .unreachable
    }
}

/// Refreshing a token, as the [SessionKeeper] needs it; the tests give a fake.
public protocol Refresher {
    func refresh(_ refreshToken: String) async -> TokenAnswer
}

/// the account service's token and revocation endpoints. [discovery] is read when a call is made, from the phone's copy.
public struct AuthEndpoints: Refresher {
    let client: AuthClient
    let transport: HttpTransport
    let discovery: () async -> Discovery?

    public func refresh(_ refreshToken: String) async -> TokenAnswer {
        await token([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", client.clientID)])
    }

    /// The browser sign-in's code, traded with its PKCE verifier.
    public func exchange(code: String, verifier: String) async -> TokenAnswer {
        await token([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", client.redirectURI),
            ("client_id", client.clientID), ("code_verifier", verifier),
        ])
    }

    /// RFC 7009, best effort: the token is forgotten on the phone whatever the account service answers.
    public func revoke(_ refreshToken: String) async {
        guard let endpoint = await discovery()?.revocationEndpoint, let url = URL(string: endpoint) else { return }
        _ = try? await transport.send(Self.formRequest(url, [
            ("token", refreshToken), ("token_type_hint", "refresh_token"), ("client_id", client.clientID),
        ]))
    }

    private func token(_ fields: [(String, String)]) async -> TokenAnswer {
        guard let found = await discovery(), let url = URL(string: found.tokenEndpoint) else { return .unreachable }
        guard let (data, response) = try? await transport.send(Self.formRequest(url, fields)) else { return .unreachable }
        return TokenAnswer.read(status: response.statusCode, body: data)
    }

    static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = AppHttp.form(fields)
        return request
    }
}
