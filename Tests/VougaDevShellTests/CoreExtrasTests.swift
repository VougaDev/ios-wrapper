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
        XCTAssertEqual(ShellConsent.cookieValue(["marketing": false, "analytics": true]), "analytics=1&marketing=0")
        let consent = ShellConsent(settings: ShellConsent.Settings(purposes: [ShellConsent.Purpose(key: "analytics", title: "A", detail: "D")]),
                                   origin: origin, defaults: freshDefaults())
        XCTAssertEqual(NativeBridge.text(consent.state()), #"{"asked":false,"choices":{}}"#)
        let cookie = consent.cookie(["analytics": true])
        XCTAssertEqual(cookie?.name, "vougadev_consent")
        XCTAssertEqual(cookie?.domain, "app.example.org")
        XCTAssertEqual(cookie?.isSecure, true)
    }
}

final class OfflineMapTests: XCTestCase {

    func testTileRanges() {
        let world = [-180.0, -85.0, 180.0, 85.0]
        XCTAssertEqual(TileMath.count(world, minZoom: 0, maxZoom: 2), 1 + 4 + 16)
        // Libreville at zoom 12: a few tiles
        let r = TileMath.range([9.40, 0.35, 9.50, 0.45], zoom: 12)
        XCTAssertEqual(r.x, 2154...2156)
        XCTAssertEqual(r.y, 2042...2044)
        XCTAssertEqual(TileMath.url("https://t.example.org/{z}/{x}/{y}.png", z: 3, x: 4, y: 5), "https://t.example.org/3/4/5.png")
    }

    func testWhatIsAccepted() {
        XCTAssertTrue(TileMath.isValid([9.4, 0.35, 9.5, 0.45]))
        XCTAssertFalse(TileMath.isValid([9.5, 0.35, 9.4, 0.45]), "west after east")
        XCTAssertFalse(TileMath.isValid([9.4, 0.35, 9.5]))
        XCTAssertTrue(OfflineMapExtension.isTemplate("https://t.example.org/{z}/{x}/{y}.png"))
        XCTAssertFalse(OfflineMapExtension.isTemplate("http://t.example.org/{z}/{x}/{y}.png"), "https only")
        XCTAssertFalse(OfflineMapExtension.isTemplate("https://t.example.org/{z}/{x}.png"))
        XCTAssertEqual(OfflineMapExtension.sourceKey("https://t.example.org/{z}/{x}/{y}.png").count, 16)
        XCTAssertEqual(OfflineMapExtension.contentType(Data([0x89, 0x50])), "image/png")
    }
}
