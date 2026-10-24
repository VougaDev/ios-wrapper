import UIKit
import UserNotifications

/// Where a tapped notification goes. One hub sends every VougaDev app's notifications, so each says which app it
/// belongs to and what it opens:
///
/// ```
/// {"aps": {"alert": {"title", "body"}}, "app": "<slug>", "url": "https://<that app's site>/…", "screen": "<key>"?,
///  "topic": "<topic>", "id": "<id>"}
/// ```
///
/// This app's notification opens the native screen an extension claims for `screen`, else its page in the web view.
/// Another app's opens its page through the system (that app, when installed and claiming the link, else Safari).
/// Never a blank screen: without a usable address, this app's home.
public enum NotificationRoute: Equatable {
    /// This app's native screen [key], with the page to fall back on when no extension claims it.
    case screen(key: String, fallback: URL?)
    case page(URL)
    case outside(URL)
    case home

    /// An older payload with a same-origin path in `url` and no `app` is this app's.
    public static func decide(_ payload: [AnyHashable: Any], appSlug: String, origin: AppOrigin) -> NotificationRoute {
        let raw = (payload["url"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let app = (payload["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appSlug
        let own: URL? = raw.hasPrefix("/") ? origin.pageURL(raw).flatMap(URL.init(string:))
            : URL(string: raw).flatMap { origin.matches($0) ? $0 : nil }
        let https = URL(string: raw).flatMap { $0.scheme?.lowercased() == "https" && $0.host?.isEmpty == false ? $0 : nil }
        if app != appSlug || (!raw.isEmpty && own == nil) { return https.map(NotificationRoute.outside) ?? .home }
        if let key = payload["screen"] as? String, key.range(of: "^[a-z][a-z0-9_.:-]{0,63}$", options: .regularExpression) != nil {
            return .screen(key: key, fallback: own)
        }
        return own.map(NotificationRoute.page) ?? .home
    }
}

/// PUSH NOTIFICATIONS, PART OF THE CORE (every app receives them; the hub sends them through APNs):
///
/// - the permission is asked right after a sign-in, once, after one native sentence (the controller's screen); a
///   refusal blocks nothing (App Review 4.5.4, 5.1.2);
/// - the installation's APNs token is reported to the app's site, which hands it to the hub, after each sign-in and
///   whenever APNs renews it: `PUT <registerPath>` `{kind: "apns", token, label, platform: "ios", locale, app}`; on
///   sign-out `POST <forgetPath>` `{token}`, while the site's session is still open;
/// - a tapped notification becomes a [NotificationRoute] for the controller, kept until it is ready.
///
/// The app's delegate hands the token over: `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` calls
/// [didRegister(deviceToken:)].
@MainActor
public final class ShellPush: NSObject, UNUserNotificationCenterDelegate {

    public struct Settings {
        /// The hub's name for this app, as its notifications carry it in `app`.
        public var appSlug: String
        /// The site's addresses that take the token, with the web view's session.
        public var registerPath: String
        public var forgetPath: String
        /// The hub's page where the person chooses topics and channels (Settings, Notifications).
        public var preferencesURL: String?

        public init(appSlug: String, registerPath: String = "/api/v1/me/push-devices",
                    forgetPath: String = "/api/v1/me/push-devices/forget", preferencesURL: String? = nil) {
            self.appSlug = appSlug
            self.registerPath = registerPath
            self.forgetPath = forgetPath
            self.preferencesURL = preferencesURL
        }
    }

    public let settings: Settings
    private unowned let session: AppSession
    private let defaults: UserDefaults
    private var pending: NotificationRoute?
    private var registeredThisRun = false

    /// The controller, once it can show a route; a route that arrived before (a cold start from a tap) waits.
    var onRoute: ((NotificationRoute) -> Void)? {
        didSet { if let route = pending, let onRoute { pending = nil; onRoute(route) } }
    }

    init(settings: Settings, session: AppSession, defaults: UserDefaults) {
        self.settings = settings
        self.session = session
        self.defaults = defaults
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked once per installation: the person answered the sentence (yes or later).
    var asked: Bool { defaults.bool(forKey: "push.asked") }

    func markAsked() { defaults.set(true, forKey: "push.asked") }

    /// The system prompt, then the registration when granted.
    func requestPermission() async {
        markAsked()
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Signed in on a page: registered again once per run when permitted (APNs may have renewed the token).
    func refreshRegistration() {
        guard !registeredThisRun else { return }
        registeredThisRun = true
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional || status == .ephemeral {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    public var permission: UNAuthorizationStatus {
        get async { await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    /// From the app's delegate. Reported while signed in; kept for the sign-out's forget.
    public func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: "push.token")
        guard session.signedIn else { return }
        Task { _ = await session.caller().putJSON(settings.registerPath, Self.report(token: token, settings: settings)) }
    }

    static func report(token: String, settings: Settings, label: String = UIDevice.current.model,
                       locale: String = Locale.current.identifier) -> JSONObject {
        ["kind": "apns", "token": token, "label": String(label.prefix(80)), "platform": "ios", "locale": locale, "app": settings.appSlug]
    }

    /// Signing out, with the caller of the still-open session: this installation stops receiving this person's pushes.
    func forget(_ caller: AppCaller) async {
        guard let token = defaults.string(forKey: "push.token") else { return }
        _ = await caller.postJSON(settings.forgetPath, ["token": token])
        registeredThisRun = false
    }

    private func deliver(_ route: NotificationRoute) {
        if let onRoute { onRoute(route) } else { pending = route }
    }

    // MARK: - UNUserNotificationCenterDelegate (the async forms: their signatures cannot drift from the SDK's)

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let payload = response.notification.request.content.userInfo
        await MainActor.run {
            self.deliver(NotificationRoute.decide(payload, appSlug: self.settings.appSlug, origin: self.session.origin))
        }
    }
}
