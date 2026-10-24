import Network
import SQLite3
import UIKit
import VougaDevShell
import WebKit

/// What the `offline-map` extension needs from the app's site:
///
/// - [manifestPath]: lists the regions this person may keep:
///   `{"available": true, "tilesets": [{"source", "name", "size", "version", "url"}]}` (`url` a same-origin path of an
///   `.mbtiles` file);
/// - [tilePath]: one tile as the site's map pages request it, `{source}`, `{z}`, `{x}` and `{y}` marked, e.g.
///   `/tiles/{source}/{z}/{x}/{y}`: such a request is answered from the phone when its region is there.
public struct OfflineMapConfig: Sendable {
    public let manifestPath: String
    public let tilePath: String

    public init(manifestPath: String, tilePath: String) {
        precondition(manifestPath.hasPrefix("/") && !manifestPath.hasPrefix("//"), "manifestPath: \(manifestPath)")
        precondition(TilePath(tilePath) != nil, "tilePath needs {source}, {z}, {x} and {y}: \(tilePath)")
        self.manifestPath = manifestPath
        self.tilePath = tilePath
    }
}

/// One tile a page asked for.
public struct TileRequest: Equatable, Sendable {
    public let source: String, z: Int, x: Int, y: Int

    /// MBTiles count rows from the bottom (TMS); the web counts from the top (XYZ).
    public var tmsRow: Int { (1 << z) - 1 - y }
}

/// The site's tile address as a pattern.
public struct TilePath: Sendable {
    let pattern: String
    let order: [String]

    public init?(_ template: String) {
        let marks = ["source", "z", "x", "y"]
        var order: [String] = []
        var pattern = "^"
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            let mark = String(rest[rest.index(after: open)..<close])
            guard marks.contains(mark) else { return nil }
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<open]))
            pattern += mark == "source" ? "([A-Za-z0-9_-]+)" : "([0-9]{1,8})"
            order.append(mark)
            rest = rest[rest.index(after: close)...]
        }
        guard order.sorted() == marks.sorted() else { return nil }
        self.pattern = pattern + NSRegularExpression.escapedPattern(for: String(rest)) + "$"
        self.order = order
    }

    /// The tile a same-origin [path] names, or nil when it is not a tile of a valid zoom and position.
    public func match(_ path: String?) -> TileRequest? {
        guard let path, let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return nil }
        var parts: [String: String] = [:]
        for (i, mark) in order.enumerated() {
            guard let range = Range(found.range(at: i + 1), in: path) else { return nil }
            parts[mark] = String(path[range])
        }
        guard let source = parts["source"], let z = Int(parts["z"] ?? ""), let x = Int(parts["x"] ?? ""), let y = Int(parts["y"] ?? ""),
              (0...24).contains(z), (0..<(1 << z)).contains(x), (0..<(1 << z)).contains(y) else { return nil }
        return TileRequest(source: source, z: z, x: x, y: y)
    }

    /// The same pattern for the page's script (a JavaScript regular expression source).
    var javaScriptPattern: String { pattern }
}

/// One region the site lists ([OfflineMapConfig.manifestPath]).
public struct Tileset: Equatable, Sendable {
    public let source: String, name: String, size: Int64, version: String, url: String

    static let namePattern = "^[A-Za-z0-9_-]+$"

    public static func parse(_ body: JSONObject?) -> [Tileset] {
        guard let body, body["available"] as? Bool != false, let rows = body["tilesets"] as? [JSONObject] else { return [] }
        return rows.compactMap { row in
            let name = row["name"] as? String ?? ""
            let url = row["url"] as? String ?? ""
            guard name.range(of: namePattern, options: .regularExpression) != nil, url.hasPrefix("/"), !url.hasPrefix("//") else { return nil }
            let source = (row["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
            return Tileset(source: source, name: name, size: (row["size"] as? NSNumber)?.int64Value ?? 0,
                           version: row["version"] as? String ?? "", url: url)
        }
    }
}

/// THE `offline-map` EXTENSION, as on the other platform: map regions kept on the phone, downloaded on Wi-Fi once signed
/// in, which answer the site's own map pages tile by tile, so they work with no network and cost no data. No member on
/// `window.VougaDevNative`: a page knows from `features().includes("offline-map")`, and its map simply keeps working.
///
/// WebKit lets an app answer only its own URL schemes, so a document-start script (main frame, and the workers the map
/// starts) sends the site's same-origin tile requests to `vougadev-tiles:`; this answers from the region's `.mbtiles`
/// file, else from the network with the web view's session, as the page would have.
@MainActor
public final class OfflineMapExtension: NSObject, ShellExtension, WKURLSchemeHandler {

    public let name = "offline-map"
    public static let scheme = "vougadev-tiles"
    public let config: OfflineMapConfig
    private let tiles: TilePath
    private weak var session: AppSession?
    private var dir: URL = FileManager.default.temporaryDirectory
    private var defaults: UserDefaults = .standard
    private var synced = false
    private var running: Set<ObjectIdentifier> = []
    private let reader = TileReader()

    public init(config: OfflineMapConfig) {
        self.config = config
        tiles = TilePath(config.tilePath)!
        super.init()
    }

    public func attach(to session: AppSession) {
        self.session = session
        defaults = session.defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent(session.config.storeName, isDirectory: true).appendingPathComponent("map", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The regions are this phone's copy of the site's data: never in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    public func configure(_ configuration: WKWebViewConfiguration) {
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        guard let origin = session?.origin else { return }
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script(origin: origin.originString, pattern: tiles.javaScriptPattern), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    /// Once per app start, signed in, on Wi-Fi.
    public func signedInPage(host: ShellHost) {
        guard !synced else { return }
        synced = true
        Task { await sync() }
    }

    public func signOut() async {
        synced = false
        reader.closeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults.removeObject(forKey: "offlineMap.versions")
        defaults.removeObject(forKey: "offlineMap.sources")
    }

    public func settingsEntries(host: ShellHost) -> [ShellSettingsEntry] {
        let files = downloaded().values
        let size = files.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }
        let summary = files.isEmpty ? ShellStrings.text("offline_map_none", bundle: .module)
            : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return [ShellSettingsEntry(title: ShellStrings.text("offline_map_title", bundle: .module), detail: summary,
                                   action: files.isEmpty ? nil : { [weak self] presenter in self?.confirmDelete(presenter) })]
    }

    private func confirmDelete(_ presenter: UIViewController) {
        let alert = UIAlertController(title: nil, message: ShellStrings.text("offline_map_delete_text", bundle: .module), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ShellStrings.text("shell_cancel", bundle: ShellResources.bundle), style: .cancel))
        alert.addAction(UIAlertAction(title: ShellStrings.text("offline_map_delete", bundle: .module), style: .destructive) { [weak self] _ in
            Task { await self?.signOut() }
        })
        presenter.present(alert, animated: true)
    }

    // MARK: - Regions

    /// The `.mbtiles` file of each source on the phone.
    func downloaded() -> [String: URL] {
        let sources = defaults.dictionary(forKey: "offlineMap.sources") as? [String: String] ?? [:]
        return sources.compactMapValues { name in
            let file = dir.appendingPathComponent("\(name).mbtiles")
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
    }

    /// The regions the site lists, downloaded when newer, on Wi-Fi only. Answers how many arrived.
    @discardableResult
    public func sync() async -> Int {
        guard let session, await Self.onWiFi() else { return 0 }
        guard case let .ok(body) = await session.caller().get(config.manifestPath) else { return 0 }
        let tilesets = Tileset.parse(body)
        guard !tilesets.isEmpty, let jar = await session.cookies.jar(), !jar.isEmpty else { return 0 }
        var versions = defaults.dictionary(forKey: "offlineMap.versions") as? [String: String] ?? [:]
        var sources = defaults.dictionary(forKey: "offlineMap.sources") as? [String: String] ?? [:]
        var arrived = 0
        for tileset in tilesets {
            let file = dir.appendingPathComponent("\(tileset.name).mbtiles")
            if FileManager.default.fileExists(atPath: file.path) && versions[tileset.name] == tileset.version { continue }
            guard let url = URL(string: session.origin.baseURL + tileset.url),
                  let headers = AppHttp.headers(origin: session.origin, cookies: jar, userAgent: session.userAgent,
                                                acceptLanguage: AppHttp.acceptLanguage(AppHttp.phoneLanguages()), unsafe: false) else { continue }
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            guard let (temp, response) = try? await URLSession.shared.download(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            reader.close(file)
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: temp)
            versions[tileset.name] = tileset.version
            sources[tileset.source] = tileset.name
            arrived += 1
        }
        defaults.set(versions, forKey: "offlineMap.versions")
        defaults.set(sources, forKey: "offlineMap.sources")
        return arrived
    }

    nonisolated static func onWiFi() async -> Bool {
        await withCheckedContinuation { done in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                done.resume(returning: path.status == .satisfied && !path.isExpensive && !path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "offline-map.path"))
        }
    }

    // MARK: - The page's tile requests

    /// Same-origin tile URLs (by [pattern], on [origin]) go to `vougadev-tiles://tile<path>`; anything else is untouched.
    /// Workers the page starts (the map's) get the same rewriting first.
    nonisolated static func script(origin: String, pattern: String) -> String {
        let originLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [origin])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        let patternLiteral = String(decoding: (try? JSONSerialization.data(withJSONObject: [pattern])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        let rewrite = """
        var ORIGIN = \(originLiteral)[0], TILE = new RegExp(\(patternLiteral)[0]);
        function vdTile(u) {
          try {
            var url = new URL(typeof u === "string" ? u : (u && u.url) || String(u), self.location.href);
            if (url.origin === ORIGIN && TILE.test(url.pathname)) { return "\(scheme)://tile" + url.pathname; }
          } catch (e) {}
          return null;
        }
        var vdFetch = self.fetch;
        if (vdFetch) {
          self.fetch = function (input, init) {
            var t = vdTile(input);
            return vdFetch.call(this, t ? t : input, t && init ? Object.assign({}, init, { credentials: "omit", mode: "cors" }) : init);
          };
        }
        if (self.XMLHttpRequest) {
          var vdOpen = self.XMLHttpRequest.prototype.open;
          self.XMLHttpRequest.prototype.open = function (method, u) {
            var t = vdTile(u);
            if (t) { arguments[1] = t; }
            return vdOpen.apply(this, arguments);
          };
        }
        """
        return """
        (function () {
          "use strict";
          if (window.location.origin !== \(originLiteral)[0]) { return; }
          \(rewrite)
          var Plain = window.Worker;
          if (Plain) {
            var prelude = URL.createObjectURL(new Blob([\(String(decoding: (try? JSONSerialization.data(withJSONObject: [rewrite])) ?? Data("[\"\"]".utf8), as: UTF8.self))[0]], { type: "text/javascript" }));
            window.Worker = function (u, options) {
              if (options && options.type === "module") { return new Plain(u, options); }
              try {
                var target = new URL(String(u), window.location.href).href;
                var boot = URL.createObjectURL(new Blob(["importScripts(" + JSON.stringify(prelude) + ", " + JSON.stringify(target) + ");"], { type: "text/javascript" }));
                return new Plain(boot, options);
              } catch (e) {
                return new Plain(u, options);
              }
            };
            window.Worker.prototype = Plain.prototype;
          }
        })();
        """
    }

    // MARK: - WKURLSchemeHandler: vougadev-tiles://tile/<the site's tile path>

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        running.insert(id)
        guard let url = urlSchemeTask.request.url, let tile = tiles.match(url.path) else {
            return finish(urlSchemeTask, id, url: urlSchemeTask.request.url, data: nil)
        }
        if let file = downloaded()[tile.source], let data = reader.tile(file, tile) {
            return finish(urlSchemeTask, id, url: url, data: data)
        }
        Task {
            finish(urlSchemeTask, id, url: url, data: await network(url.path))
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        running.remove(ObjectIdentifier(urlSchemeTask))
    }

    /// The tile from the site, as the page would have asked it (with the web view's session).
    private func network(_ path: String) async -> Data? {
        guard let session, let url = URL(string: session.origin.baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        if let jar = await session.cookies.jar(), let headers = AppHttp.headers(origin: session.origin, cookies: jar, userAgent: session.userAgent,
                                                                                acceptLanguage: AppHttp.acceptLanguage(AppHttp.phoneLanguages()), unsafe: false) {
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// A task WebKit stopped is never answered (WebKit raises on it).
    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, url: URL?, data: Data?) {
        guard running.remove(id) != nil, let url else { return }
        let body = data.map(Self.inflated)
        let headers = ["Access-Control-Allow-Origin": session?.origin.originString ?? "*", "Content-Type": Self.contentType(body),
                       "Cache-Control": "no-store"]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body ?? Data())
        task.didFinish()
    }

    nonisolated static func contentType(_ data: Data?) -> String {
        switch data?.first {
        case 0x89: return "image/png"
        case 0xFF: return "image/jpeg"
        case 0x52: return "image/webp"
        default: return "application/x-protobuf"
        }
    }

    /// MBTiles keep vector tiles gzipped, and a page's map expects them as the network gives them: decompressed. The
    /// gzip header and trailer go, the DEFLATE body is inflated by Foundation (`.zlib` is raw DEFLATE).
    nonisolated static func inflated(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return data }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0, at + 2 <= bytes.count { at += 2 + (Int(bytes[at]) | (Int(bytes[at + 1]) << 8)) }  // FEXTRA
        if flags & 0x08 != 0 { while at < bytes.count && bytes[at] != 0 { at += 1 }; at += 1 }             // FNAME
        if flags & 0x10 != 0 { while at < bytes.count && bytes[at] != 0 { at += 1 }; at += 1 }             // FCOMMENT
        if flags & 0x02 != 0 { at += 2 }                                                                  // FHCRC
        guard at < bytes.count - 8,
              let body = try? (Data(bytes[at..<(bytes.count - 8)]) as NSData).decompressed(using: .zlib) else { return data }
        return body as Data
    }
}

/// The `.mbtiles` files, opened once each, read-only.
final class TileReader: @unchecked Sendable {
    private var open: [URL: OpaquePointer] = [:]
    private let lock = NSLock()

    func tile(_ file: URL, _ tile: TileRequest) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db = database(file) else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(tile.z))
        sqlite3_bind_int(statement, 2, Int32(tile.x))
        sqlite3_bind_int(statement, 3, Int32(tile.tmsRow))
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func close(_ file: URL) {
        lock.lock()
        defer { lock.unlock() }
        if let db = open.removeValue(forKey: file) { sqlite3_close(db) }
    }

    func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        open.values.forEach { sqlite3_close($0) }
        open.removeAll()
    }

    private func database(_ file: URL) -> OpaquePointer? {
        if let db = open[file] { return db }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        open[file] = db
        return db
    }
}

/// The extension's resource bundle (its Settings texts), for tests and tools.
public enum OfflineMapResources {
    public static let bundle = Bundle.module
}
