import XCTest
@testable import VougaDevOfflineMap
@testable import VougaDevShell

/// The regions' manifest, the tile origins and what the phone answers for them.
final class OfflineMapTests: XCTestCase {
    let config = OfflineMapConfig(manifestPath: "/missions/map/offline", tilePath: "/tiles/{source}/{z}/{x}/{y}")
    let shared = OfflineMapConfig(manifestPath: "/missions/map/offline", tilePath: "/tiles/{source}/{z}/{x}/{y}",
                                  tileOrigins: ["https://maps.vougadev.com"])

    func testSameOriginFilesGoWithTheSessionAndNoToken() {
        let rows = Tileset.parse([
            "available": true,
            "tilesets": [
                ["source": "gabon", "name": "gabon", "size": 46_137_344, "version": "1774", "url": "/maps/offline/gabon", "token": "t"],
                ["name": "../etc", "url": "/x"], ["name": "h3", "url": "https://elsewhere/h3.mbtiles"], ["name": "h4", "url": "//elsewhere/h4"],
            ] as [JSONObject],
        ], config: config)
        XCTAssertEqual(rows.map(\.name), ["gabon"])
        XCTAssertNil(rows[0].token)
        XCTAssertTrue(Tileset.parse(["available": false, "tilesets": [["name": "gabon", "url": "/x"]] as [JSONObject]], config: config).isEmpty)
    }

    func testAFileOnATileOriginKeepsItsTokenForTheDownload() {
        let body: JSONObject = [
            "available": true,
            "tilesets": [
                ["source": "gabon", "name": "gabon.mbtiles", "size": 46_137_344, "version": "69bfece3-2c00000",
                 "url": "https://maps.vougadev.com/offline/gabon.mbtiles", "token": "eyJ.a-b_c"],
                ["name": "h1", "url": "https://maps.vougadev.com.evil.example/offline/h1.mbtiles"],
                ["name": "h2", "url": "http://maps.vougadev.com/offline/h2.mbtiles"],
                ["name": "h3", "url": "https://maps.vougadev.com/offline/h3.mbtiles", "token": "bad token\r\nX: y"],
            ] as [JSONObject],
        ]
        let rows = Tileset.parse(body, config: shared)
        XCTAssertEqual(rows.map(\.name), ["gabon", "h3"])
        XCTAssertEqual(rows[0].source, "gabon")
        XCTAssertEqual(rows[0].size, 46_137_344)
        XCTAssertEqual(rows[0].version, "69bfece3-2c00000")
        XCTAssertEqual(rows[0].token, "eyJ.a-b_c")
        XCTAssertNil(rows[1].token)
        XCTAssertTrue(Tileset.parse(body, config: config).isEmpty, "without tileOrigins nothing leaves the site")
    }

    func testTileOriginsAreExactHttpsOrigins() {
        XCTAssertEqual(shared.tileOrigin(of: "https://maps.vougadev.com/tiles/gabon/1/0/0"), "https://maps.vougadev.com")
        XCTAssertNil(shared.tileOrigin(of: "https://maps.vougadev.com:8443/tiles/gabon/1/0/0"))
        XCTAssertNil(shared.tileOrigin(of: "http://maps.vougadev.com/tiles/gabon/1/0/0"))
        XCTAssertNil(shared.tileOrigin(of: "https://proxi.vougadev.com/tiles/gabon/1/0/0"))
        XCTAssertTrue(OfflineMapConfig.isOrigin("https://maps.vougadev.com"))
        for bad in ["http://maps.vougadev.com", "https://maps.vougadev.com/", "https://maps.vougadev.com/tiles", "maps.vougadev.com"] {
            XCTAssertFalse(OfflineMapConfig.isOrigin(bad), bad)
        }
    }

    func testThePagesRequestsToATileOriginAreSentToTheApp() {
        let script = OfflineMapExtension.script(origin: "https://proxi.vougadev.com", pattern: "^/tiles/([A-Za-z0-9_-]+)/([0-9]{1,8})/([0-9]{1,8})/([0-9]{1,8})$",
                                                tileOrigins: ["https://maps.vougadev.com"])
        XCTAssertTrue(script.contains("MAPS = [\"https:\\/\\/maps.vougadev.com\"]") || script.contains("MAPS = [\"https://maps.vougadev.com\"]"))
        XCTAssertTrue(script.contains("vougadev-tiles://\" + url.host + url.pathname + url.search"))
    }

    func testAPreflightAllowsWhatThePageAskedForAndNothingForged() {
        let headers = OfflineMapExtension.preflightHeaders(["access-control-request-headers": "authorization, x-a\r\nb, accept"])
        XCTAssertEqual(headers["Access-Control-Allow-Headers"], "authorization, accept")
        XCTAssertEqual(headers["Access-Control-Allow-Methods"], "GET, OPTIONS")
        XCTAssertEqual(OfflineMapExtension.preflightHeaders([:])["Access-Control-Allow-Headers"], "Authorization")
    }

    func testAKeptStyleOrGlyphComesBackAsItCame() throws {
        let body = Data([0x1A, 0x0A, 0x00, 0x7F])
        let kept = try XCTUnwrap(KeptAnswers.decode(KeptAnswers.encode(type: "application/x-protobuf", body: body)))
        XCTAssertEqual(kept.type, "application/x-protobuf")
        XCTAssertEqual(kept.body, body)
        XCTAssertNil(KeptAnswers.decode(Data()))
        XCTAssertEqual(KeptAnswers.key("https://maps.vougadev.com/tiles/font/Noto/0-255.pbf").count, 64)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        KeptAnswers.save(in: dir, url: "https://maps.vougadev.com/tiles/style/pivo_light", type: "application/json", body: Data("{}".utf8))
        XCTAssertEqual(KeptAnswers.read(in: dir, url: "https://maps.vougadev.com/tiles/style/pivo_light")?.body, Data("{}".utf8))
        XCTAssertNil(KeptAnswers.read(in: dir, url: "https://maps.vougadev.com/tiles/style/pivo_dark"))
    }
}
