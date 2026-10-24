import Foundation

/// A JSON object as `JSONSerialization` reads and writes it: the bridge's arguments and answers, the API's bodies.
public typealias JSONObject = [String: Any]

/// One origin the shell trusts: the site's web app, or the account service where the person signs in.
///
/// Everything that grants something - loading a page inside the web view, the `window.VougaDevNative` bridge, a photo -
/// asks this type first, and it answers with scheme, host and port only. A path or a query never makes a foreign page
/// trusted, and `app.example.org.evil.io` or `app.example.org@evil.io` are other hosts, which is what a URL parser (not a
/// string prefix) says they are.
public struct AppOrigin: Equatable, Sendable {

    /// The base URL without a trailing slash, e.g. `https://app.example.org`.
    public let baseURL: String
    let scheme: String
    let host: String
    let port: Int

    /// [baseURL] is the app's own configuration: a wrong one stops the app at launch, never later.
    public init(_ baseURL: String) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { preconditionFailure("Base URL must be http(s)://host[:port]: \(baseURL)") }
        self.baseURL = trimmed
        self.scheme = scheme
        self.host = host
        self.port = Self.effectivePort(scheme, parts.port ?? -1)
    }

    /// `scheme://host[:port]`, the port only when it is not the scheme's default: what `location.origin` says.
    public var originString: String {
        port == Self.effectivePort(scheme, -1) ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// True when [url] is on this origin. A malformed or relative URL is never trusted.
    public func matches(_ url: String?) -> Bool {
        guard let text = url?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let parts = URLComponents(string: text) else { return false }
        return matchesParts(scheme: parts.scheme, host: parts.host, port: parts.port ?? -1)
    }

    public func matches(_ url: URL?) -> Bool {
        guard let url else { return false }
        return matchesParts(scheme: url.scheme, host: url.host, port: url.port ?? -1)
    }

    /// The same test from the parts of a parsed URL; [port] is -1 (or 0, as WebKit's security origin says) when none.
    public func matchesParts(scheme: String?, host: String?, port: Int) -> Bool {
        guard let scheme = scheme?.lowercased(), let host = host?.lowercased() else { return false }
        return scheme == self.scheme && host == self.host && Self.effectivePort(scheme, port == 0 ? -1 : port) == self.port
    }

    /// The absolute URL of a page on this origin, or nil when [path] is not a same-origin PATH: `/`-rooted, no `//host`,
    /// no backslash, no whitespace or control character, at most 2048 characters. A query is kept.
    public func pageURL(_ path: String?) -> String? {
        guard let path, path.count <= Self.maxPagePath, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        if path.unicodeScalars.contains(where: { $0.value <= 0x20 || $0 == "\\" || $0.value == 0x7F }) { return nil }
        let url = baseURL + path
        return matches(url) ? url : nil
    }

    static let maxPagePath = 2048

    static func effectivePort(_ scheme: String, _ port: Int) -> Int {
        if port != -1 { return port }
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return -1
        }
    }
}

/// The path of [url] as the server routes it, trailing slash kept (`URL.path` drops it).
func routePath(_ url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
}
