import UIKit
import VougaDevOfflineMap
import VougaDevShell
import VougaDevTracking

/// THE EXAMPLE APP: what an app built on the shell writes in its own repository (README.md, "An app on the shell").
/// It builds in CI and is never submitted: a store app has its own site, name, icon, account-service client and native features.
extension ShellConfig {
    static let app = ShellConfig(
        baseURL: "https://app.example.org",
        authBaseURL: "https://auth.example.org",
        authClientID: "example-ios",
        userAgentToken: "Example",
        colors: ShellColors(
            background: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.08, green: 0.13, blue: 0.17, alpha: 1) : .white },
            accent: UIColor(red: 0.84, green: 0.66, blue: 0.30, alpha: 1),
            onAccent: UIColor(red: 0.08, green: 0.13, blue: 0.17, alpha: 1)
        ),
        mark: UIImage(systemName: "shippingbox.fill"),
        authSignInPaths: ["/authorize", "/login"],
        accountDeletionURL: "https://auth.example.org/account/delete/",
        inspectable: isDebug
    )

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// One sign-in per process: the web view, tracking and later push share it.
    /// The core plus the extensions this app uses: what `VougaDevNative.features()` lists.
    @MainActor static let session = AppSession(config: .app, extensions: [
        TrackingExtension(paths: TrackingPaths(position: "/api/missions/{id}/position", target: "/api/missions/tracking", endedCodes: ["mission_over"])),
        OfflineMapExtension(config: OfflineMapConfig(manifestPath: "/api/map/offline", tilePath: "/tiles/{source}/{z}/{x}/{y}")),
    ])

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        _ = AppDelegate.session  // made now: a notification tapped while the app was closed finds its delegate
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppDelegate.session.push?.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ShellViewController(session: AppDelegate.session)
        window.makeKeyAndVisible()
        self.window = window
    }
}
