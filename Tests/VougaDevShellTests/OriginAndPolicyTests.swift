import XCTest
@testable import VougaDevShell

final class OriginAndPolicyTests: XCTestCase {

    func testOriginMatchesSchemeHostAndPortOnly() {
        XCTAssertTrue(origin.matches("https://app.example.org/courier/missions/?a=1"))
        XCTAssertTrue(origin.matches("https://APP.example.org:443/"))
        XCTAssertFalse(origin.matches("http://app.example.org/"))
        XCTAssertFalse(origin.matches("https://app.example.org:8443/"))
        XCTAssertFalse(origin.matches("https://app.example.org.evil.io/"))
        XCTAssertFalse(origin.matches("https://app.example.org@evil.io/"))
        XCTAssertFalse(origin.matches("/relative"))
        XCTAssertFalse(origin.matches(""))
        XCTAssertFalse(origin.matches(nil as String?))
        XCTAssertTrue(origin.matchesParts(scheme: "https", host: "app.example.org", port: 0), "WebKit's default port is 0")
        XCTAssertEqual(origin.originString, "https://app.example.org")
        XCTAssertEqual(AppOrigin("http://localhost:8000/").originString, "http://localhost:8000")
        XCTAssertEqual(AppOrigin("https://app.example.org///").baseURL, "https://app.example.org")
    }

    func testPageURLTakesOnlySameOriginPaths() {
        XCTAssertEqual(origin.pageURL("/courier/missions/?tab=mine"), "https://app.example.org/courier/missions/?tab=mine")
        XCTAssertNil(origin.pageURL("//evil.io/"))
        XCTAssertNil(origin.pageURL("https://evil.io/"))
        XCTAssertNil(origin.pageURL("/a b"))
        XCTAssertNil(origin.pageURL("/a\\b"))
        XCTAssertNil(origin.pageURL("/" + String(repeating: "a", count: 2048)))
        XCTAssertNil(origin.pageURL(nil))
    }

    func testLinkPolicyTable() {
        func decide(_ scheme: String?, site: Bool = false, auth: Bool = false, native: Bool = false, path: String? = nil) -> LinkPolicy.Decision {
            LinkPolicy.decide(scheme: scheme, isSite: site, isAuth: auth, isNativeRoute: native, path: path, authSignInPaths: ["/authorize", "/login"])
        }
        XCTAssertEqual(decide("https", site: true, path: "/"), .loadInside)
        XCTAssertEqual(decide("https", site: true, path: "/auth/login/"), .signIn)
        XCTAssertEqual(decide("https", site: true, path: "/auth/login"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/authorize/"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/login/?next=x"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/account/delete/"), .openOutside)
        XCTAssertEqual(decide("https", site: true, native: true, path: "/courier/missions/"), .openNative)
        XCTAssertEqual(decide("https", path: "/"), .openOutside)
        XCTAssertEqual(decide("tel"), .openOutside)
        XCTAssertEqual(decide("intent"), .openIntent)
        XCTAssertEqual(decide("javascript"), .block)
        XCTAssertEqual(decide("file"), .block)
        XCTAssertEqual(decide("about"), .block)
        XCTAssertEqual(decide(nil), .block)
    }

    func testSignInRoute() {
        XCTAssertTrue(SignInRoute.isSignOut(method: "post", isSite: true, path: "/auth/logout/"))
        XCTAssertFalse(SignInRoute.isSignOut(method: "GET", isSite: true, path: "/auth/logout/"))
        XCTAssertFalse(SignInRoute.isSignOut(method: "POST", isSite: false, path: "/auth/logout/"))
        XCTAssertEqual(SignInRoute.after(origin, next: "/shipments/?x=1"), "https://app.example.org/shipments/?x=1")
        XCTAssertEqual(SignInRoute.after(origin, next: "/auth/login/"), "https://app.example.org/")
        XCTAssertEqual(SignInRoute.after(origin, next: "https://evil.io/"), "https://app.example.org/")
        XCTAssertEqual(SignInRoute.after(origin, next: nil), "https://app.example.org/")
    }

    func testRoutePathKeepsTheTrailingSlash() {
        XCTAssertEqual(routePath(URL(string: "https://app.example.org/courier/missions/?a=1")!), "/courier/missions/")
    }
}
