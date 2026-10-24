import UIKit
import XCTest
@testable import VougaDevShell
@testable import VougaDevTracking

final class BridgeTests: XCTestCase {

    func testScriptChecksTheOriginAndListsTheMembers() {
        let script = NativeShim.script(origin: origin, version: "1.0\"; alert(1); \"", features: ["tracking", "offline-map"], methods: ["startTracking", "openSettings"])
        XCTAssertTrue(script.contains(#"if (window.location.origin !== "https:\/\/app.example.org") { return; }"#))
        XCTAssertTrue(script.contains(#"platform: function () { return "ios"; }"#))
        XCTAssertTrue(script.contains(#"return "1.0\"; alert(1); \"";"#), "the version cannot break out of its literal")
        XCTAssertTrue(script.contains(#"startTracking: function (args) { return call("startTracking", args); }"#))
        XCTAssertTrue(script.contains(#"var features = Object.freeze(["tracking", "offline-map"]);"#))
        XCTAssertTrue(script.contains("features: function () { return features.slice(); }"))
        XCTAssertTrue(script.contains("Object.freeze"))
        XCTAssertTrue(script.contains("writable: false"))
        XCTAssertTrue(script.contains("window.webkit.messageHandlers"))
        XCTAssertTrue(NativeShim.isMethodName("trackingState"))
        XCTAssertFalse(NativeShim.isMethodName("x-y"))
        XCTAssertFalse(NativeShim.isMethodName("Upper"))
    }

    private func call(_ bridge: NativeBridge, _ body: Any, mainFrame: Bool = true, host: String = "app.example.org") -> JSONObject? {
        var reply: String?
        bridge.onMessage(body, isMainFrame: mainFrame, scheme: "https", host: host, port: 0) { reply = $0 }
        return reply.map(json)
    }

    func testBridgeRoutesAndRefuses() {
        let bridge = NativeBridge(origin: origin, methods: ["echo": { args, answer in answer(["ok": true, "got": args ?? [:]]) }])
        XCTAssertEqual(call(bridge, #"{"method":"echo","args":{"a":1}}"#)?["got"] as? [String: Int], ["a": 1])
        XCTAssertEqual(call(bridge, #"{"method":"echo"}"#, host: "evil.io")?["error"] as? String, "origin_refused")
        XCTAssertEqual(call(bridge, #"{"method":"echo"}"#, mainFrame: false)?["error"] as? String, "origin_refused")
        XCTAssertEqual(call(bridge, "not json")?["error"] as? String, "invalid_json")
        XCTAssertEqual(call(bridge, 42)?["error"] as? String, "invalid_json")
        XCTAssertEqual(call(bridge, #"{"method":"nope"}"#)?["error"] as? String, "unknown_method")
    }

    func testEveryCallIsAnsweredExactlyOnce() {
        var kept: ((JSONObject) -> Void)?
        let bridge = NativeBridge(origin: origin, methods: [
            "twice": { _, answer in answer(["n": 1]); answer(["n": 2]) },
            "later": { _, answer in kept = answer },
            "never": { _, _ in },
        ])
        var replies: [String] = []
        bridge.onMessage(#"{"method":"twice"}"#, isMainFrame: true, scheme: "https", host: "app.example.org", port: 443) { replies.append($0) }
        XCTAssertEqual(replies, [#"{"n":1}"#])
        bridge.onMessage(#"{"method":"never"}"#, isMainFrame: true, scheme: "https", host: "app.example.org", port: 443) { replies.append($0) }
        XCTAssertEqual(json(replies[1])["error"] as? String, "bridge_unavailable")
        bridge.onMessage(#"{"method":"later"}"#, isMainFrame: true, scheme: "https", host: "app.example.org", port: 443) { replies.append($0) }
        XCTAssertEqual(replies.count, 2)
        kept?(["ok": true])
        XCTAssertEqual(replies.last, #"{"ok":true}"#)
    }

    func testRepliesAreAlwaysJSON() {
        XCTAssertEqual(NativeBridge.text(["bad": Date()]), #"{"error":"bridge_unavailable","ok":false}"#)
        XCTAssertEqual(NativeBridge.text(["x": NSNull()]), #"{"x":null}"#)
    }

    /// A delegate method whose signature drifted from WebKit's is never called, silently: the selectors must be there.
    @MainActor
    func testTheControllerAnswersWebKitsDelegateSelectors() {
        let config = ShellConfig(baseURL: "https://app.example.org", authBaseURL: "https://auth.example.org",
                                 authClientID: "test-client", userAgentToken: "Test",
                                 push: ShellPush.Settings(appSlug: "test"))
        let tracking = TrackingExtension(paths: paths)
        let session = AppSession(config: config, extensions: [tracking])
        XCTAssertNotNil(tracking.service, "attached to the session")
        XCTAssertEqual(session.features, ["tracking"])
        let controller = ShellViewController(session: session)
        for selector in [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:didCommitNavigation:",
            "webView:didFinishNavigation:",
            "webView:didFailProvisionalNavigation:withError:",
            "webViewWebContentProcessDidTerminate:",
            "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        ] {
            XCTAssertTrue(controller.responds(to: NSSelectorFromString(selector)), selector)
        }
        XCTAssertEqual(controller.bridgeMethods().map { $0.0 }, ["openSettings", "consent", "startTracking", "stopTracking", "trackingState"])
        XCTAssertEqual(AppSession.missingRequirements([tracking], info: [:]),
                       ["NSLocationWhenInUseUsageDescription", "UIBackgroundModes: location", "NSLocationTemporaryUsageDescriptionDictionary: Tracking"])
        XCTAssertEqual(AppSession.missingRequirements([tracking], info: [
            "NSLocationWhenInUseUsageDescription": "why", "UIBackgroundModes": ["location"],
            "NSLocationTemporaryUsageDescriptionDictionary": ["Tracking": "why"],
        ]), [])
    }
}
