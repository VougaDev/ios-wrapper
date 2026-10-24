import CryptoKit
import Network
import UIKit
import WebKit

/// THE SITE'S PAGES KEPT ON THE PHONE, so the app stays useful with no network (App Review 4.2: a dead end offline is a
/// repackaged website). Each page of the site the person opens is kept as a web archive (the page and its assets: styles,
/// scripts, images), newest first, up to [maxBytes] in all, the oldest going first. With no network, the web view shows
/// the kept copy under a quiet "Offline · updated at …" bar; a page never opened offers the kept ones instead. Cleared at
/// sign-out: the next person sees nothing of this one.
@MainActor
public final class OfflinePages {

    public struct Entry: Codable, Equatable {
        /// The page's address, without its fragment.
        public let url: String
        public let title: String
        public let savedAt: Date
        public let size: Int
        let file: String
    }

    /// What all kept pages may take on the phone; the oldest go first.
    var maxBytes = 60 * 1024 * 1024
    static let maxEntries = 300
    private let dir: URL
    private let defaults: UserDefaults
    private let key = "offline.pages"

    init(storeName: String, defaults: UserDefaults) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent(storeName, isDirectory: true).appendingPathComponent("offline-pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // This phone's copy of the person's pages: never in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = dir
        try? folder.setResourceValues(values)
    }

    /// Newest first.
    public var entries: [Entry] {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    private func write(_ list: [Entry]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }

    /// The address a page is kept under: no fragment.
    static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    public func entry(for url: URL) -> Entry? {
        let wanted = Self.normalized(url)
        return entries.first { $0.url == wanted }
    }

    func archive(_ entry: Entry) -> Data? { try? Data(contentsOf: dir.appendingPathComponent(entry.file)) }

    /// Keeps [data] (a web archive) for [url], newest first, then lets the oldest go beyond the limits.
    func store(_ data: Data, url: URL, title: String, now: Date = Date()) {
        let address = Self.normalized(url)
        let file = SHA256.hash(data: Data(address.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".webarchive"
        guard (try? data.write(to: dir.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return }
        var list = entries.filter { $0.url != address }
        list.insert(Entry(url: address, title: String(title.prefix(200)), savedAt: now, size: data.count, file: file), at: 0)
        var total = 0
        var kept: [Entry] = []
        for item in list {
            total += item.size
            if kept.count < Self.maxEntries && total <= maxBytes { kept.append(item) } else { try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.file)) }
        }
        write(kept)
    }

    /// The page the web view shows now, kept (a page of the site, loaded from the network, answered 200).
    func save(_ webView: WKWebView, url: URL) async {
        let title = webView.title ?? ""
        let data: Data? = await withCheckedContinuation { done in
            webView.createWebArchiveData { result in done.resume(returning: try? result.get()) }
        }
        if let data { store(data, url: url, title: title) }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults.removeObject(forKey: key)
    }
}

/// Whether the phone can reach the network, as the system says it; [simulated] (Debug, the UI tests) answers "no".
@MainActor
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private let simulated: Bool
    private(set) var online = true
    private var known = false
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    var onChange: ((Bool) -> Void)?

    init(simulatedOffline: Bool) {
        simulated = simulatedOffline
        if simulated {
            online = false
            known = true
            return
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.update(up) }
        }
        monitor.start(queue: DispatchQueue(label: "vougadev.network"))
    }

    private func update(_ up: Bool) {
        let changed = known && up != online
        online = up
        known = true
        waiting.forEach { $0.resume(returning: up) }
        waiting.removeAll()
        if changed { onChange?(up) }
    }

    /// The first answer, at most a second away (the system answers at once on a phone).
    func current() async -> Bool {
        if known { return online }
        return await withCheckedContinuation { done in
            waiting.append(done)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !self.known { self.update(true) }
            }
        }
    }
}

/// The quiet bar over a kept page: "Offline · updated at 14:32".
final class OfflineBar: UIView {
    private let label = UILabel()

    init(colors: ShellColors) {
        super.init(frame: .zero)
        backgroundColor = colors.background.withAlphaComponent(0.94)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = colors.muted
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "shell.offline.bar"
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Built in code") }

    func show(savedAt: Date) {
        let today = Calendar.current.isDateInToday(savedAt)
        let when = DateFormatter.localizedString(from: savedAt, dateStyle: today ? .none : .short, timeStyle: .short)
        label.text = String(format: Strings.text("shell_offline_bar"), when)
        isHidden = false
    }
}
