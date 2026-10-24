import Foundation

/// The native end of `window.VougaDevNative` ([NativeShim]): one message in, one reply out, handed to the app's own
/// methods by name.
///
/// The shim only runs in main frames of the app's origin, and this checks the sending frame again anyway: WebKit gives
/// every frame `window.webkit.messageHandlers`, so a cross-origin frame inside a page could post here directly. That
/// frame, or any frame that is not the main one, is answered `origin_refused`.
///
/// Every call is answered exactly once with a JSON text, however often a method calls its answer; a method that drops
/// its answer without calling it answers `bridge_unavailable` (WebKit insists the reply handler is called).
public final class NativeBridge {

    /// One member of the app's features. Called on the main thread with the call's `args` object (nil when the page gave
    /// none, or not an object); `answer` may be called long after this returns - after the person answered the system
    /// dialogs.
    public typealias Method = (_ args: JSONObject?, _ answer: @escaping (JSONObject) -> Void) -> Void

    public static let refusedOrigin = "origin_refused"
    public static let unknownMethod = "unknown_method"
    public static let invalidJSON = "invalid_json"

    let roles: [NativeShim.Role]
    let methods: [String: Method]

    /// [roles]: which origin may call which members, and whether its frames inside a page may ([NativeShim.Role]).
    public init(roles: [NativeShim.Role], methods: [String: Method]) {
        self.roles = roles
        self.methods = methods
    }

    /// [body] is the message's body; [scheme], [host], [port] are the sending frame's security origin.
    public func onMessage(_ body: Any, isMainFrame: Bool, scheme: String?, host: String?, port: Int, reply: @escaping (String) -> Void) {
        let once = Once(reply)
        guard let role = roles.first(where: { $0.origin.matchesParts(scheme: scheme, host: host, port: port) }),
              isMainFrame || role.frames else {
            return once.send(Self.refused(Self.refusedOrigin))
        }
        guard let text = body as? String, let data = text.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            return once.send(Self.refused(Self.invalidJSON))
        }
        guard let name = envelope["method"] as? String, let method = methods[name] else {
            return once.send(Self.refused(Self.unknownMethod))
        }
        // A member this origin does not have (the shim never offers it there).
        guard role.members.contains(name) else { return once.send(Self.refused(Self.refusedOrigin)) }
        // An object is the arguments; a single value (`nativeSignIn("google")`) comes as `{"value": …}`.
        let raw = envelope["args"]
        let args = raw as? JSONObject ?? ((raw == nil || raw is NSNull) ? nil : ["value": raw!])
        method(args) { once.send($0) }
    }

    public static func ok() -> JSONObject { ["ok": true] }

    public static func refused(_ reason: String) -> JSONObject { ["ok": false, "error": reason] }

    /// JSON text of [object]; an object JSON cannot carry is `bridge_unavailable`, never a crash.
    static func text(_ object: JSONObject) -> String {
        let safe = JSONSerialization.isValidJSONObject(object) ? object : refused(NativeShim.errorUnavailable)
        let data = (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private final class Once {
        private var reply: ((String) -> Void)?

        init(_ reply: @escaping (String) -> Void) { self.reply = reply }

        func send(_ result: JSONObject) {
            guard let reply else { return }
            self.reply = nil
            reply(NativeBridge.text(result))
        }

        deinit { send(NativeBridge.refused(NativeShim.errorUnavailable)) }
    }
}
