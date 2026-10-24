import CryptoKit
import UIKit
import VougaDevShell
import WebKit

/// Slippy-map tile arithmetic (Web Mercator, `{z}/{x}/{y}`).
public enum TileMath {
    /// The tile columns and rows a box covers at [zoom]; [bbox] is `[west, south, east, north]` in degrees.
    public static func range(_ bbox: [Double], zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let n = 1 << zoom
        func column(_ lng: Double) -> Int { min(n - 1, max(0, Int(floor((lng + 180) / 360 * Double(n))))) }
        func row(_ lat: Double) -> Int {
            let clamped = min(85.0511, max(-85.0511, lat)) * .pi / 180
            return min(n - 1, max(0, Int(floor((1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2 * Double(n)))))
        }
        return (column(bbox[0])...column(bbox[2]), row(bbox[3])...row(bbox[1]))
    }

    public static func count(_ bbox: [Double], minZoom: Int, maxZoom: Int) -> Int {
        (minZoom...maxZoom).reduce(0) { total, zoom in
            let r = range(bbox, zoom: zoom)
            return total + r.x.count * r.y.count
        }
    }

    /// [template] with `{z}`, `{x}`, `{y}` filled in.
    public static func url(_ template: String, z: Int, x: Int, y: Int) -> String {
        template.replacingOccurrences(of: "{z}", with: "\(z)").replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
    }

    /// A box the app can save: four numbers in range, west < east, south < north.
    public static func isValid(_ bbox: [Double]) -> Bool {
        bbox.count == 4 && bbox.allSatisfy(\.isFinite) && (-180...180).contains(bbox[0]) && (-180...180).contains(bbox[2])
            && (-90...90).contains(bbox[1]) && (-90...90).contains(bbox[3]) && bbox[0] < bbox[2] && bbox[1] < bbox[3]
    }
}

/// THE `offline-map` EXTENSION: the site's own maps keep working without a network. Regions are saved on the phone,
/// and the page's map loads its tiles through `vougadev-tiles://` (a `WKURLSchemeHandler`): from the phone when saved,
/// else from the network (and kept). Its members of `window.VougaDevNative`:
///
/// ```
/// offlineTiles({tiles})                                       -> Promise<{ok: true, url} | {ok: false, error}>
/// saveOfflineRegion({id, name?, tiles, bbox, minZoom, maxZoom}) -> Promise<{ok: true, total} | {ok: false, error}>
/// offlineRegions()                                            -> Promise<{ok: true, regions: [{id, name, total, saved, state}]}>
/// deleteOfflineRegion({id})                                   -> Promise<{ok: true}>
/// ```
///
/// `tiles` is the page's https template (`https://…/{z}/{x}/{y}.png`); `url` is what the map uses instead
/// (`vougadev-tiles://<source>/{z}/{x}/{y}`). `bbox` is `[west, south, east, north]`. Codes: `invalid_tiles`,
/// `invalid_region`, `region_too_large` (more than [maxTilesPerRegion] tiles).
@MainActor
public final class OfflineMapExtension: NSObject, ShellExtension, WKURLSchemeHandler {

    public let name = "offline-map"
    public static let scheme = "vougadev-tiles"
    public static let maxTilesPerRegion = 20_000
    public static let maxZoom = 18

    private var defaults: UserDefaults = .standard
    private var root: URL = FileManager.default.temporaryDirectory
    private var running: Set<ObjectIdentifier> = []
    private var downloads: [String: Task<Void, Never>] = [:]
    private let session = URLSession(configuration: .default)

    public override init() { super.init() }

    public func attach(to session: AppSession) {
        defaults = session.defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent(session.config.storeName, isDirectory: true).appendingPathComponent("tiles", isDirectory: true)
        // Saved tiles are the person's data for this phone: not in iCloud backups.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        // A download cut by the app's end is paused; saving the region again resumes it (saved tiles are skipped).
        regions = regions.map { var region = $0; if region["state"] as? String == "downloading" { region["state"] = "paused" }; return region }
    }

    public func configure(_ configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
    }

    // MARK: - Sources and regions

    /// The page's https template by source key.
    private var sources: [String: String] {
        get { defaults.dictionary(forKey: "offlineMap.sources") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "offlineMap.sources") }
    }

    private var regions: [JSONObject] {
        get { defaults.array(forKey: "offlineMap.regions") as? [JSONObject] ?? [] }
        set { defaults.set(newValue, forKey: "offlineMap.regions") }
    }

    /// A template's key: the same template, the same tiles on the phone.
    static func sourceKey(_ template: String) -> String {
        SHA256.hash(data: Data(template.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isTemplate(_ template: String?) -> Bool {
        guard let template, template.hasPrefix("https://"), URL(string: TileMath.url(template, z: 0, x: 0, y: 0)) != nil else { return false }
        return ["{z}", "{x}", "{y}"].allSatisfy(template.contains)
    }

    private func register(_ template: String) -> String {
        let key = Self.sourceKey(template)
        sources[key] = template
        return key
    }

    private func file(_ key: String, _ z: Int, _ x: Int, _ y: Int) -> URL {
        root.appendingPathComponent("\(key)/\(z)/\(x)/\(y)")
    }

    private func update(_ id: String, _ change: (inout JSONObject) -> Void) {
        regions = regions.map { var region = $0; if region["id"] as? String == id { change(&region) }; return region }
    }

    // MARK: - Members

    public func bridgeMethods(host: ShellHost) -> [(String, NativeBridge.Method)] {
        [
            ("offlineTiles", { [weak self] args, answer in
                guard let self, let template = args?["tiles"] as? String, Self.isTemplate(template) else {
                    return answer(NativeBridge.refused("invalid_tiles"))
                }
                answer(["ok": true, "url": "\(Self.scheme)://\(self.register(template))/{z}/{x}/{y}"])
            }),
            ("saveOfflineRegion", { [weak self] args, answer in
                guard let self else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                answer(self.save(args))
            }),
            ("offlineRegions", { [weak self] _, answer in
                let list = (self?.regions ?? []).map { region in
                    region.filter { ["id", "name", "total", "saved", "state"].contains($0.key) }
                }
                answer(["ok": true, "regions": list])
            }),
            ("deleteOfflineRegion", { [weak self] args, answer in
                if let id = args?["id"] as? String { self?.delete(id) }
                answer(NativeBridge.ok())
            }),
        ]
    }

    private func save(_ args: JSONObject?) -> JSONObject {
        guard let template = args?["tiles"] as? String, Self.isTemplate(template) else { return NativeBridge.refused("invalid_tiles") }
        guard let id = (args?["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id.count <= 100,
              let bbox = (args?["bbox"] as? [NSNumber])?.map(\.doubleValue), TileMath.isValid(bbox),
              let minZoom = (args?["minZoom"] as? NSNumber)?.intValue, let maxZoom = (args?["maxZoom"] as? NSNumber)?.intValue,
              0 <= minZoom, minZoom <= maxZoom, maxZoom <= Self.maxZoom
        else { return NativeBridge.refused("invalid_region") }
        let total = TileMath.count(bbox, minZoom: minZoom, maxZoom: maxZoom)
        guard total <= Self.maxTilesPerRegion else { return NativeBridge.refused("region_too_large") }
        let key = register(template)
        let region: JSONObject = [
            "id": id, "name": String((args?["name"] as? String ?? id).prefix(100)), "source": key, "bbox": bbox,
            "minZoom": minZoom, "maxZoom": maxZoom, "total": total, "saved": 0, "state": "downloading",
        ]
        regions = regions.filter { $0["id"] as? String != id } + [region]
        download(id: id, key: key, template: template, bbox: bbox, zooms: minZoom...maxZoom)
        return ["ok": true, "total": total]
    }

    /// shortcut: a deleted region's tiles stay while another region of the same source exists (tiles are shared);
    /// count references per tile if regions of one source often overlap and get deleted.
    private func delete(_ id: String) {
        downloads.removeValue(forKey: id)?.cancel()
        let source = regions.first { $0["id"] as? String == id }?["source"] as? String
        regions = regions.filter { $0["id"] as? String != id }
        if let source, !regions.contains(where: { $0["source"] as? String == source }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(source))
        }
    }

    private func download(id: String, key: String, template: String, bbox: [Double], zooms: ClosedRange<Int>) {
        downloads[id]?.cancel()
        downloads[id] = Task { [weak self] in
            var saved = 0, failed = 0
            for z in zooms {
                let range = TileMath.range(bbox, zoom: z)
                for x in range.x {
                    for y in range.y {
                        if Task.isCancelled { return }
                        guard let self else { return }
                        if await self.fetch(key: key, template: template, z: z, x: x, y: y) != nil { saved += 1 } else { failed += 1 }
                        if (saved + failed) % 50 == 0 { self.update(id) { $0["saved"] = saved } }
                    }
                }
            }
            self?.update(id) { $0["saved"] = saved; $0["state"] = failed == 0 ? "done" : "incomplete" }
            self?.downloads[id] = nil
        }
    }

    /// The tile from the phone, else from the network (kept); nil when neither has it.
    private func fetch(key: String, template: String, z: Int, x: Int, y: Int) async -> Data? {
        let path = file(key, z, x, y)
        if let kept = try? Data(contentsOf: path) { return kept }
        guard let url = URL(string: TileMath.url(template, z: z, x: x, y: y)),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
        return data
    }

    // MARK: - WKURLSchemeHandler: vougadev-tiles://<source>/<z>/<x>/<y>

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        running.insert(id)
        let url = urlSchemeTask.request.url
        let parts = url?.pathComponents.filter { $0 != "/" }.compactMap { Int($0.split(separator: ".").first ?? "") } ?? []
        guard let url, let key = url.host, let template = sources[key], parts.count == 3 else {
            return finish(urlSchemeTask, id, url: url, data: nil)
        }
        Task {
            let data = await fetch(key: key, template: template, z: parts[0], x: parts[1], y: parts[2])
            finish(urlSchemeTask, id, url: url, data: data)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// A task WebKit stopped is never answered (WebKit raises on it).
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, url: URL?, data: Data?) {
        guard running.remove(id) != nil, let url else { return }
        let headers = ["Access-Control-Allow-Origin": "*", "Content-Type": Self.contentType(data), "Cache-Control": "max-age=86400"]
        let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data ?? Data())
        task.didFinish()
    }

    static func contentType(_ data: Data?) -> String {
        guard let first = data?.first else { return "application/octet-stream" }
        switch first {
        case 0x89: return "image/png"
        case 0xFF: return "image/jpeg"
        case 0x52: return "image/webp"
        case 0x1F: return "application/x-protobuf"  // a gzipped vector tile
        default: return "application/x-protobuf"
        }
    }
}
