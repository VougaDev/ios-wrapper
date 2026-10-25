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
        func decide(_ scheme: String?, site: Bool = false, auth: Bool = false, company: Bool = false, native: Bool = false, path: String? = nil) -> LinkPolicy.Decision {
            LinkPolicy.decide(scheme: scheme, isSite: site, isAuth: auth, isCompany: company, isNativeRoute: native, path: path,
                              authSignInPaths: ["/authorize", "/login"])
        }
        XCTAssertEqual(decide("https", site: true, path: "/"), .loadInside)
        XCTAssertEqual(decide("https", site: true, path: "/auth/login/"), .signIn)
        XCTAssertEqual(decide("https", site: true, path: "/auth/login"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/authorize/"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/login/?next=x"), .signIn)
        XCTAssertEqual(decide("https", auth: true, path: "/account/delete/"), .loadInside, "the account service's pages: inside")
        XCTAssertEqual(decide("https", company: true, path: "/terms/"), .loadInside, "a company domain: inside")
        XCTAssertEqual(LinkPolicy.decide(scheme: "https", isSite: false, isAuth: true, isNativeRoute: false, path: "/login/",
                                         authSignInPaths: ["/login"], signInInWebView: true), .loadInside, "the sign-in in the web view")
        XCTAssertEqual(decide("https", site: true, native: true, path: "/courier/missions/"), .openNative)
        XCTAssertEqual(decide("https", path: "/"), .openSheet, "an outside company's site: an in-app sheet")
        XCTAssertEqual(decide("mailto"), .openOutside)
        XCTAssertEqual(LinkPolicy.decide(scheme: "https", isSite: false, isAuth: false, isNativeRoute: false,
                                         isAppLink: LinkPolicy.isCompany(host: "t.me", domains: LinkPolicy.appHosts)), .openOutside,
                       "Telegram's links open Telegram")
        XCTAssertTrue(LinkPolicy.isCompany(host: "telegram.me", domains: LinkPolicy.appHosts))
        XCTAssertTrue(LinkPolicy.isCompany(host: "pay.example.org", domains: ["example.org"]))
        XCTAssertTrue(LinkPolicy.isCompany(host: "EXAMPLE.org", domains: ["example.org"]))
        XCTAssertFalse(LinkPolicy.isCompany(host: "evilexample.org", domains: ["example.org"]))
        XCTAssertFalse(LinkPolicy.isCompany(host: "example.org.evil.io", domains: ["example.org"]))
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
        let items = { (query: String) in URLComponents(string: "https://app.example.org/auth/login/?" + query)!.queryItems ?? [] }
        XCTAssertEqual(SignInRoute.asks(items("next=/x/")), [:], "a plain sign-in renews silently")
        XCTAssertEqual(SignInRoute.asks(items("prompt=create&next=/x/")), ["prompt": "create"], "a sign-up")
        XCTAssertEqual(SignInRoute.asks(items("prompt=select_account&max_age=0")), ["prompt": "select_account", "max_age": "0"])
        XCTAssertEqual(SignInRoute.asks(items("prompt=none&max_age=-1")), [:], "nothing else is passed on")
    }

    func testRoutePathKeepsTheTrailingSlash() {
        XCTAssertEqual(routePath(URL(string: "https://app.example.org/courier/missions/?a=1")!), "/courier/missions/")
    }
}
