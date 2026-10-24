import Foundation

/// One call to the site's API as the web view's session ([AppHttp]'s headers), classified ([ApiOutcome]).
///
/// A LOST SESSION IS RENEWED BEFORE IT IS REPORTED: [renew] refreshes the the account service token and opens a new site session, and
/// the call is made once more with the new cookies. Only when the renewal needs the person to sign in is the answer
/// `sessionLost`; when the account service or the site cannot be reached it is `offline`.
public struct AppCaller {
    let origin: AppOrigin
    let cookies: () async -> String?
    let userAgent: () -> String
    let acceptLanguage: () -> String
    let renew: (_ lostJar: String?) async -> Renewal
    let transport: HttpTransport

    public init(origin: AppOrigin, cookies: @escaping () async -> String?, userAgent: @escaping () -> String,
                acceptLanguage: @escaping () -> String, renew: @escaping (String?) async -> Renewal,
                transport: HttpTransport = AppHttp.transport) {
        self.origin = origin
        self.cookies = cookies
        self.userAgent = userAgent
        self.acceptLanguage = acceptLanguage
        self.renew = renew
        self.transport = transport
    }

    public func get(_ path: String) async -> ApiOutcome { await call(path, method: "GET", body: nil) }

    public func postJSON(_ path: String, _ body: JSONObject) async -> ApiOutcome {
        await call(path, method: "POST", body: try? JSONSerialization.data(withJSONObject: body))
    }

    private func call(_ path: String, method: String, body: Data?) async -> ApiOutcome {
        let jar = await cookies()
        let first = await once(jar, path, method, body)
        guard first.isSessionLost else { return first }
        switch await renew(jar) {
        case .renewed: return await once(await cookies(), path, method, body)
        case .offline: return .offline
        case .signIn: return .sessionLost
        }
    }

    private func once(_ jar: String?, _ path: String, _ method: String, _ body: Data?) async -> ApiOutcome {
        guard let jar, !jar.isEmpty, let url = URL(string: origin.baseURL + path),
              let headers = AppHttp.headers(origin: origin, cookies: jar, userAgent: userAgent(), acceptLanguage: acceptLanguage(), unsafe: method != "GET")
        else { return .sessionLost }
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await transport.send(request)
            return ApiOutcome.classify(status: response.statusCode, body: data)
        } catch {
            return .offline
        }
    }
}
