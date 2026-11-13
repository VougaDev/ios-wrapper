import UIKit
import UniformTypeIdentifiers
import VougaDevShell

/// Files another app opened in this one, copied into the app's caches the moment they arrive (the system's copy in
/// `Documents/Inbox` is removed), until the page takes them once with `sharedFiles()`. Emptied on sign-out.
public enum DocumentsInbox {

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("documents-inbox", isDirectory: true)
    }

    /// One file as the page receives it: `{name, type, size, data}`, `data` in base64.
    public static func payload(name: String, type: String, data: Data) -> JSONObject {
        ["name": name, "type": type, "size": data.count, "data": data.base64EncodedString()]
    }

    /// A name the site can show: no path, no control characters, at most 200 characters, never empty.
    public static func cleanName(_ raw: String?, fallback: String) -> String {
        let last = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : String(name.prefix(200))
    }

    /// The media type of a file from its name, as the page and the site expect it.
    public static func mediaType(of url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
    }

    /// Copies the taken files into the inbox (what the page has not taken yet is replaced: one share at a time);
    /// how many were taken. A type outside [config], a file too large or unreadable is left out.
    @discardableResult
    public static func receive(_ urls: [URL], config: DocumentsConfig) -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var taken = 0
        for (i, url) in urls.enumerated() {
            defer { if url.path.contains("/Documents/Inbox/") { try? fm.removeItem(at: url) } }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let type = mediaType(of: url), config.types.contains(type),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= config.maxBytes,
                  let data = try? Data(contentsOf: url) else { continue }
            let meta: [String: String] = ["name": cleanName(url.lastPathComponent, fallback: "document-\(i + 1)"), "type": type]
            guard (try? data.write(to: directory.appendingPathComponent("\(i).bin"))) != nil,
                  (try? JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("\(i).json"))) != nil
            else { continue }
            taken += 1
        }
        return taken
    }

    /// The waiting files, handed over once.
    public static func take() -> [JSONObject] {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: directory) }
        let metas = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
            .sorted { (Int($0.split(separator: ".")[0]) ?? 0) < (Int($1.split(separator: ".")[0]) ?? 0) }
        return metas.compactMap { file in
            let index = file.replacingOccurrences(of: ".json", with: "")
            guard let raw = try? Data(contentsOf: directory.appendingPathComponent(file)),
                  let meta = try? JSONSerialization.jsonObject(with: raw) as? [String: String],
                  let name = meta["name"], let type = meta["type"],
                  let data = try? Data(contentsOf: directory.appendingPathComponent("\(index).bin")) else { return nil }
            return payload(name: name, type: type, data: data)
        }
    }

    public static func forget() { try? FileManager.default.removeItem(at: directory) }

    /// One PDF of the scanned pages, each on a page of its own size (72 dpi of a ~1600 px wide picture, JPEG at 0.7).
    public static func pdf(_ pages: [UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            for page in pages {
                let image = page.jpegData(compressionQuality: 0.7).flatMap(UIImage.init(data:)) ?? page
                let width: CGFloat = 595
                let height = max(1, width * image.size.height / max(1, image.size.width))
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }

    /// A scan's date and time in its name: `2026-11-13 10.42`.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }
}
