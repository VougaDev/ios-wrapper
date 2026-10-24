import Foundation

/// What one call to the site's API answered, read from its status and body. The site refuses with RFC 9457 problem
/// bodies: `{"type", "title", "status", "detail", "code"}`, `detail` translated into the request's language.
public enum ApiOutcome {
    case ok(JSONObject)

    /// The server said no, in its own words.
    case refused(status: Int, code: String, detail: String)

    /// No network, or it broke mid-call.
    case offline

    /// The web view's session is gone: a redirect (to the sign-in), a 401, or a 403 without a problem body (the site's
    /// CSRF refusal).
    case sessionLost

    /// Neither an answer nor a refusal (an edge's HTML error page, a body that is not JSON).
    case failed(status: Int)

    public static func classify(status: Int, body: Data?) -> ApiOutcome {
        let json = parse(body)
        let detail = json?["detail"] as? String ?? ""
        let code = json?["code"] as? String ?? ""
        switch status {
        case 200...299 where json != nil: return .ok(json!)
        case 300...399, 401: return .sessionLost
        case 403 where json == nil: return .sessionLost
        default:
            if json != nil && (!detail.isEmpty || !code.isEmpty) { return .refused(status: status, code: code, detail: detail) }
            return .failed(status: status)
        }
    }

    public var isSessionLost: Bool { if case .sessionLost = self { return true } else { return false } }

    static func parse(_ body: Data?) -> JSONObject? {
        guard let body, let text = String(data: body, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? JSONObject
    }
}
