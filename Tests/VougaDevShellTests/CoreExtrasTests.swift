import XCTest
@testable import VougaDevOfflineMap
@testable import VougaDevShell

final class NotificationRouteTests: XCTestCase {

    private func decide(_ payload: [AnyHashable: Any]) -> NotificationRoute {
        NotificationRoute.decide(payload, appSlug: "ship", origin: origin)
    }

    func testThisAppsNotificationOpensItsScreenOrPage() {
        let page = URL(string: "https://app.example.org/shipments/S-1/")!
        XCTAssertEqual(decide(["app": "ship", "url": page.absoluteString]), .page(page))
        XCTAssertEqual(decide(["app": "ship", "url": page.absoluteString, "screen": "mission"]), .screen(key: "mission", fallback: page))
        XCTAssertEqual(decide(["url": page.absoluteString]), .page(page), "no app named: this one's")
    }

    func testAnotherAppsNotificationOpensOutside() {
        let other = URL(string: "https://jobs.example.org/offers/1/")!
        XCTAssertEqual(decide(["app": "jobs", "url": other.absoluteString, "screen": "offer"]), .outside(other))
        XCTAssertEqual(decide(["app": "ship", "url": other.absoluteString]), .outside(other), "this app's, but on another site")
    }

    func testNeverABlankScreen() {
        XCTAssertEqual(decide([:]), .home)
        XCTAssertEqual(decide(["app": "ship", "url": "javascript:alert(1)"]), .home)
        XCTAssertEqual(decide(["url": "/shipments/S-1/"]), .page(URL(string: "https://app.example.org/shipments/S-1/")!), "an older payload's path")
        XCTAssertEqual(decide(["app": "ship", "url": "/a b"]), .home)
        XCTAssertEqual(decide(["app": "ship", "screen": "Bad Key"]), .home)
        XCTAssertEqual(decide(["app": "jobs", "url": "http://jobs.example.org/"]), .home, "https only")
        XCTAssertEqual(decide(["app": "ship", "screen": "mission"]), .screen(key: "mission", fallback: nil))
    }

    @MainActor
    func testTheTokenReportNamesTheAppAndPlatform() {
        let report = ShellPush.report(token: "abc", settings: ShellPush.Settings(appSlug: "ship"), label: "iPhone", locale: "fr_FR")
        XCTAssertEqual(NativeBridge.text(report), #"{"app":"ship","kind":"apns","label":"iPhone","locale":"fr_FR","platform":"ios","token":"abc"}"#)
    }

    @MainActor
    func testConsentGoesToTheSiteAsACookie() {
        let consent = ShellConsent(settings: ShellConsent.Settings(purposes: [
            ShellConsent.Purpose(key: "analytics", title: "A", detail: "D"), ShellConsent.Purpose(key: "ads", title: "B", detail: "E"),
        ]), origin: origin, defaults: freshDefaults())
        XCTAssertEqual(consent.cookieValue(["ads": false, "analytics": true]), "analytics:1|ads:0")
        XCTAssertEqual(NativeBridge.text(consent.state()), #"{"ads":false,"analytics":false}"#, "off until turned on")
        let cookie = consent.cookie(["analytics": true])
        XCTAssertEqual(cookie?.name, "vougadev_consent")
        XCTAssertEqual(cookie?.domain, "app.example.org")
        XCTAssertEqual(cookie?.isSecure, true)
    }
}

final class EdgeAndSignInTests: XCTestCase {

    func testTheEdgesFailuresAreNeverShown() {
        for status in [502, 503, 504, 520, 522, 530] { XCTAssertTrue(ShellViewController.isEdgeError(status), "\(status)") }
        for status in [200, 400, 403, 404, 500] { XCTAssertFalse(ShellViewController.isEdgeError(status), "\(status): the site's own page") }
    }

    func testGooglesSignInForAnIOSClient() {
        XCTAssertEqual(NativeSignIn.googleScheme("1234-abcd.apps.googleusercontent.com"), "com.googleusercontent.apps.1234-abcd")
        let request = AuthorizeRequest(state: "st", nonce: "no", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = NativeSignIn.googleAuthorizeURL(clientID: "1234-abcd.apps.googleusercontent.com", request: request, nonce: "page-nonce")!
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        XCTAssertEqual(items["nonce"], "page-nonce")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(url.host, "accounts.google.com")
    }
}

@MainActor
final class OfflinePagesTests: XCTestCase {

    func testPagesAreKeptNewestFirstAndTheOldestGo() {
        let pages = OfflinePages(storeName: "test-offline-\(UUID().uuidString)", defaults: freshDefaults())
        pages.maxBytes = 25
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        pages.store(Data(repeating: 1, count: 10), url: URL(string: "https://app.example.org/a/#top")!, title: "A", now: base)
        pages.store(Data(repeating: 2, count: 10), url: URL(string: "https://app.example.org/b/?x=1")!, title: "B", now: base + 1)
        XCTAssertEqual(pages.entries.map(\.title), ["B", "A"])
        XCTAssertEqual(pages.entry(for: URL(string: "https://app.example.org/a/")!)?.title, "A", "kept without its fragment")
        XCTAssertNil(pages.entry(for: URL(string: "https://app.example.org/b/")!), "the query is part of the page")
        pages.store(Data(repeating: 3, count: 10), url: URL(string: "https://app.example.org/c/")!, title: "C", now: base + 2)
        XCTAssertEqual(pages.entries.map(\.title), ["C", "B"], "beyond the limit the oldest went")
        pages.store(Data(repeating: 4, count: 10), url: URL(string: "https://app.example.org/b/?x=1")!, title: "B2", now: base + 3)
        XCTAssertEqual(pages.entries.map(\.title), ["B2", "C"], "opened again: newest")
        XCTAssertEqual(pages.archive(pages.entries[0]), Data(repeating: 4, count: 10))
        pages.clear()
        XCTAssertTrue(pages.entries.isEmpty)
        XCTAssertEqual(OfflinePages.title("Votre colis ne voyage plus au hasard · Ship", appName: "Ship"), "Votre colis ne voyage plus au hasard")
        XCTAssertEqual(OfflinePages.title(" Confidentialité ", appName: "Ship"), "Confidentialité")
    }
}

final class OfflineMapTests: XCTestCase {

    func testTilePathMatchesTheSitesTiles() {
        let path = TilePath("/tiles/{source}/{z}/{x}/{y}.pbf")!
        XCTAssertEqual(path.match("/tiles/gabon/12/2154/2042.pbf"), TileRequest(source: "gabon", z: 12, x: 2154, y: 2042))
        XCTAssertEqual(path.match("/tiles/gabon/12/2154/2042.pbf")?.tmsRow, 4096 - 1 - 2042)
        XCTAssertNil(path.match("/tiles/gabon/2/4/0.pbf"), "x out of range at zoom 2")
        XCTAssertNil(path.match("/tiles/../12/1/1.pbf"))
        XCTAssertNil(path.match("/static/app.js"))
        XCTAssertNil(TilePath("/tiles/{z}/{x}/{y}"), "no {source}")
    }

    func testTheManifest() {
        let sets = Tileset.parse(json(#"{"available": true, "tilesets": [{"source": "gabon", "name": "gabon-2026", "size": 12, "version": "v3", "url": "/media/map/gabon.mbtiles"}, {"name": "../x", "url": "/a"}, {"name": "far", "url": "https://evil.io/f"}]}"#))
        XCTAssertEqual(sets, [Tileset(source: "gabon", name: "gabon-2026", size: 12, version: "v3", url: "/media/map/gabon.mbtiles")])
        XCTAssertEqual(Tileset.parse(json(#"{"available": false, "tilesets": [{"name": "a", "url": "/a"}]}"#)), [])
    }

    func testGzippedTilesAreInflated() {
        let gzipped = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xFF, 0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28, 0xC9,
                            0xCC, 0x49, 0x05, 0x00, 0xEF, 0x9F, 0xB4, 0x93, 0x0A, 0x00, 0x00, 0x00])
        XCTAssertEqual(String(decoding: OfflineMapExtension.inflated(gzipped), as: UTF8.self), "hello tile")
        XCTAssertEqual(OfflineMapExtension.inflated(Data([0x89, 0x50, 0x4E])), Data([0x89, 0x50, 0x4E]), "a PNG stays as it is")
        XCTAssertEqual(OfflineMapExtension.contentType(Data([0x89, 0x50])), "image/png")
    }

    func testThePageScriptOnlyRewritesTheSitesTiles() {
        let script = OfflineMapExtension.script(origin: "https://app.example.org", pattern: TilePath("/tiles/{source}/{z}/{x}/{y}")!.javaScriptPattern)
        XCTAssertTrue(script.contains(#"if (window.location.origin !== ["https:\/\/app.example.org"][0]) { return; }"#))
        XCTAssertTrue(script.contains("vougadev-tiles://tile"))
        XCTAssertTrue(script.contains("window.Worker = function"))
    }
}
