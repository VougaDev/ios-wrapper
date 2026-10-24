import Foundation

/// `window.VougaDevNative`, the one native interface a page sees - the name and shape every VougaDev app keeps on every
/// platform (docs/integration/native-bridge.md in each app). Two members are the shell's and every app has them:
///
/// ```
/// VougaDevNative.platform()            -> "ios"                      (sync, a constant)
/// VougaDevNative.version()             -> "1.0.0"                    (sync, CFBundleShortVersionString)
/// VougaDevNative.features()            -> ["tracking", "push", …]    (sync, the extensions present)
/// ```
///
/// The others are the core's (`openSettings`, `consent`) and those of the extensions the app has, each
/// `name(args) -> Promise<{ok: true, ...} | {ok: false, error}>`. A Promise always resolves, never rejects. The object
/// is frozen and cannot be replaced.
///
/// Two WebKit features carry it: a document-start [script] in main frames only that returns at once unless
/// `location.origin` is the app's, and a `WKScriptMessageHandlerWithReply` named [handler] that checks the frame again
/// ([NativeBridge]). Each call is one JSON text `{"method": "...", "args": {...} | null}`; the reply is one JSON text,
/// the call's result. WebKit's own Promise is wrapped so that a refusal of WebKit's still resolves.
public enum NativeShim {

    /// The page-facing object.
    public static let name = "VougaDevNative"

    /// The message handler; only the shim uses it.
    public static let handler = "vougadevNative"

    public static let platform = "ios"

    /// What the Promise resolves with when the handler is missing or the argument cannot be sent.
    public static let errorUnavailable = "bridge_unavailable"
    public static let errorInvalidRequest = "invalid_request"

    /// The members every app has, before its own.
    public static let builtIn = ["platform", "version", "features"]

    /// [version] is the app's version name and [origin] its origin, both written as JSON string literals so they cannot
    /// break out of them; [methods] are the app's members, in the order its contract lists them (plain identifiers only).
    public static func script(origin: AppOrigin, version: String, features: [String], methods: [String]) -> String {
        precondition(
            methods.allSatisfy(isMethodName) && methods.allSatisfy { !builtIn.contains($0) } && Set(methods).count == methods.count,
            "Bridge members must be distinct identifiers other than \(builtIn): \(methods)"
        )
        let featureList = "[" + features.map(quote).joined(separator: ", ") + "]"
        let members = methods.map { ",\n    \($0): function (args) { return call(\"\($0)\", args); }" }.joined()
        return """
        (function () {
          "use strict";
          if (window.location.origin !== \(quote(origin.originString))) { return; }
          if (window.\(name)) { return; }
          var handlers = window.webkit && window.webkit.messageHandlers;
          var h = handlers ? handlers.\(handler) : null;
          var unavailable = { ok: false, error: \(quote(errorUnavailable)) };
          var features = Object.freeze(\(featureList));
          function call(method, args) {
            return new Promise(function (resolve) {
              if (!h || typeof h.postMessage !== "function") { resolve(unavailable); return; }
              var text;
              try { text = JSON.stringify({ method: method, args: args === undefined ? null : args }); }
              catch (e) { resolve({ ok: false, error: \(quote(errorInvalidRequest)) }); return; }
              var sent;
              try { sent = h.postMessage(text); } catch (e) { resolve(unavailable); return; }
              Promise.resolve(sent).then(function (reply) {
                var result = null;
                try { result = JSON.parse(reply); } catch (e) { result = null; }
                resolve(result && typeof result === "object" ? result : unavailable);
              }, function () { resolve(unavailable); });
            });
          }
          var api = Object.freeze({
            platform: function () { return \(quote(platform)); },
            version: function () { return \(quote(version)); },
            features: function () { return features.slice(); }\(members)
          });
          Object.defineProperty(window, \(quote(name)), { value: api, writable: false, enumerable: false, configurable: false });
        })();
        """
    }

    static func isMethodName(_ name: String) -> Bool {
        name.range(of: "^[a-z][A-Za-z0-9]*$", options: .regularExpression) != nil
    }

    /// A JSON string literal, which is a JavaScript string literal too.
    static func quote(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }
}
