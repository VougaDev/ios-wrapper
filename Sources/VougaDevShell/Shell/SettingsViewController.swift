import UIKit

/// THE APP'S NATIVE SETTINGS, never in the site's main menu: a page opens it with `VougaDevNative.openSettings()` (an
/// item of its account menu, shown only inside the app).
///
/// - the app's version;
/// - Notifications: the system permission, and the hub's page that chooses topics and channels;
/// - Privacy and data: the privacy policy (the site's page), cookies and data (the consent dialog again), deleting the
///   account (the account service's page, in Safari);
/// - Sign out of this app on this phone.
@MainActor
final class SettingsViewController: UITableViewController {

    private enum Row {
        case version, permission, topics, privacy, consent, deleteAccount, signOut
    }

    private let session: AppSession
    private let openPage: (String) -> Void
    private let signOut: () -> Void
    private var sections: [(title: String?, rows: [Row])] = []
    private var permissionText = ""

    init(session: AppSession, openPage: @escaping (String) -> Void, signOut: @escaping () -> Void) {
        self.session = session
        self.openPage = openPage
        self.signOut = signOut
        super.init(style: .insetGrouped)
        title = Strings.text("settings_title")
        let config = session.config
        sections.append((Strings.text("settings_app"), [.version]))
        if let push = config.push {
            sections.append((Strings.text("settings_notifications"), push.preferencesURL == nil ? [.permission] : [.permission, .topics]))
        }
        var privacy: [Row] = []
        if config.privacyPath != nil { privacy.append(.privacy) }
        if config.consent != nil { privacy.append(.consent) }
        if config.accountDeletionURL != nil { privacy.append(.deleteAccount) }
        if !privacy.isEmpty { sections.append((Strings.text("settings_privacy"), privacy)) }
        if session.signedIn { sections.append((nil, [.signOut])) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Built in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "shell.settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let push = session.push else { return }
        Task {
            let status = await push.permission
            permissionText = Strings.text(status == .authorized || status == .provisional ? "settings_notifications_on" : "settings_notifications_off")
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.accessoryType = .disclosureIndicator
        switch sections[indexPath.section].rows[indexPath.row] {
        case .version:
            content.text = Strings.text("settings_version")
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            content.secondaryText = "\(session.config.versionName) (\(build))"
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .permission:
            content.text = Strings.text("settings_notifications_permission")
            content.secondaryText = permissionText
        case .topics: content.text = Strings.text("settings_notifications_topics")
        case .privacy: content.text = Strings.text("settings_privacy_policy")
        case .consent: content.text = Strings.text("settings_consent")
        case .deleteAccount: content.text = Strings.text("settings_delete_account")
        case .signOut:
            content = UIListContentConfiguration.cell()
            content.text = Strings.text("settings_sign_out")
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let config = session.config
        switch sections[indexPath.section].rows[indexPath.row] {
        case .version: break
        case .permission:
            Task {
                // Never asked: the system prompt now; asked before: only the system's Settings can change it.
                if await session.push?.permission == .notDetermined {
                    await session.push?.requestPermission()
                    viewWillAppear(false)
                } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
            }
        case .topics:
            if let url = config.push?.preferencesURL.flatMap(URL.init(string:)) { UIApplication.shared.open(url) }
        case .privacy:
            if let url = session.origin.pageURL(config.privacyPath) { dismiss(animated: true) { self.openPage(url) } }
        case .consent:
            session.consent?.ask(from: self, again: true) {}
        case .deleteAccount:
            if let url = config.accountDeletionURL.flatMap(URL.init(string:)) { UIApplication.shared.open(url) }
        case .signOut:
            let confirm = UIAlertController(title: nil, message: String(format: Strings.text("settings_sign_out_confirm"), Strings.appName()),
                                            preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: Strings.text("shell_cancel"), style: .cancel))
            confirm.addAction(UIAlertAction(title: Strings.text("settings_sign_out"), style: .destructive) { _ in
                self.dismiss(animated: true) { self.signOut() }
            })
            present(confirm, animated: true)
        }
    }
}
