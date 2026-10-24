import UIKit
import WebKit

/// THE SHELL'S ONE SCREEN (VougaDev Native, README.md): the app's site in a `WKWebView`, and what a page cannot do on
/// its own - the native sign-in, a native offline screen, links handed to the apps that open them, the features the app
/// turns on. An app subclasses it only to add its own: native screens for paths ([nativeScreen]), more bridge members
/// ([bridgeMethods]) and the hooks below.
///
/// SIGN-IN IS NATIVE, IN THE SYSTEM'S SIGN-IN SHEET (The account service's rule: never a web view). The app signs in with the account service
/// ([BrowserSignIn]), trades the access token for the site's session (`/auth/app-session/`) and puts its cookies in the
/// web view's store. When the web view heads for a sign-in (`/auth/login/`, the account service's pages) the session is renewed
/// silently ([SessionKeeper]); only a refused refresh shows the sign-in screen, one button. The web's sign-out form is
/// taken over: the app's [beforeSignOut], the site's session ended, the refresh token revoked, everything of the person
/// cleared on the phone - never the VougaDev session.
///
/// Only the app's origin is ever loaded or granted anything ([AppOrigin]). `window.VougaDevNative` is injected there
/// only ([NativeShim], [NativeBridge]).
@MainActor
open class ShellViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, ShellHost {

    public let session: AppSession
    public var origin: AppOrigin { session.origin }
    private let auth: AppOrigin
    public private(set) var webView: WKWebView!
    private lazy var panel = ShellPanel(colors: session.config.colors)
    private lazy var browser = BrowserSignIn(session: session)
    private enum Screen { case working, signingOut, signIn, failed, offlineSignIn, offlinePage, askPush }

    private var screen: Screen?
    /// The page to open once the session is open (the sign-in's `next`).
    private var afterSignIn: String?
    private var signingOut = false
    /// The URL whose main-frame load failed, reloaded by Try again.
    private var failedURL: URL?
    private var booted = false

    public init(session: AppSession) {
        self.session = session
        auth = AppOrigin(session.config.authBaseURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("Built in code") }

    // MARK: - What the app adds

    /// The members of `window.VougaDevNative` beyond `platform()`, `version()` and `features()`: the core's
    /// (`openSettings`, `consent`), then each extension's, in the order the app lists its extensions.
    open func bridgeMethods() -> [(String, NativeBridge.Method)] {
        coreMethods() + session.extensions.flatMap { $0.bridgeMethods(host: self) }
    }

    /// The native screen a same-origin [path] (no query, trailing slash kept) opens instead of loading it, or nil to
    /// load it in the web view: the first extension that claims it. Fixed in the binary (App Review 2.5.2).
    open func nativeScreen(path: String) -> UIViewController? {
        session.extensions.lazy.compactMap { $0.nativeScreen(path: path, host: self) }.first
    }

    /// The controller dialogs and native screens are presented from: the topmost one shown.
    public var presenter: UIViewController {
        var top: UIViewController = self
        while let shown = top.presentedViewController { top = shown }
        return top
    }

    /// A page of the site finished loading with the session open.
    open func onSignedInPage() {}

    /// A person just signed in with the sheet (not a silent renewal).
    open func afterNewSignIn() {}

    /// The web's sign-out is starting: stop what works for this person.
    open func beforeSignOut() {}

    /// What the app keeps of a person goes: never signed in with the app, or the account service refused the refresh.
    open func forgetLocalData() {}

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = session.config.colors.background
        installWebView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        panel.onButton = { [weak self] in self?.onPanelButton() }
        panel.onLink = { [weak self] in self?.onPanelLink() }
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.session.extensions.forEach { $0.becameActive(host: self) }
            }
        }
        // A tapped notification; one that arrived before this screen existed (a cold start) is handed over now.
        session.push?.onRoute = { [weak self] in self?.route($0) }
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !booted else { return }
        booted = true
        boot()
    }

    /// This start's first screen. Never signed in on this phone: the sign-in screen (cookies left by anything else are
    /// not the app's, they go). Signed in but the site's session gone: renewed first. Else the home page.
    private func boot() {
        guard session.signedIn else {
            Task {
                await session.cookies.clear()
                forgetLocalData()
            }
            show(.signIn)
            return
        }
        Task {
            if SessionCookies.isSignedIn(await session.cookies.jar()) {
                let target = afterSignIn ?? home
                afterSignIn = nil
                open(target)
            } else {
                renewThen(nil)
            }
        }
    }

    private var home: String { origin.baseURL + "/" }

    // MARK: - The web view

    private func installWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = AppHttp.applicationName(token: session.config.userAgentToken, version: session.config.versionName)
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        installNativeBridge(config.userContentController)
        session.extensions.forEach { $0.configure(config) }

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = session.config.inspectable
        web.isOpaque = false
        web.backgroundColor = session.config.colors.background
        let refresh = UIRefreshControl()
        // shortcut: a pull over an open modal reloads the page too (Android asks the page first, PullGuard); add that
        // check here when a site's modals hold long forms.
        refresh.addAction(UIAction { [weak web] _ in web?.reload() }, for: .valueChanged)
        web.scrollView.refreshControl = refresh
        web.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(web, at: 0)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        webView = web
    }

    /// A new web view, with no history: another person may have used the phone before, and has no way back to their pages.
    private func replaceWebView() {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        installWebView()
    }

    /// `window.VougaDevNative` in main frames of the app's origin only: the document-start script (it returns at once on
    /// any other origin) and the reply handler, which checks the sending frame itself ([NativeBridge]).
    private func installNativeBridge(_ controller: WKUserContentController) {
        let methods = bridgeMethods()
        let bridge = NativeBridge(origin: origin, methods: Dictionary(methods, uniquingKeysWith: { first, _ in first }))
        let script = NativeShim.script(origin: origin, version: session.config.versionName, features: session.features,
                                       methods: methods.map { $0.0 })
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(BridgeHandler(bridge), contentWorld: .page, name: NativeShim.handler)
    }

    /// A page by URL: a native screen opens over the home page; anything else loads here. With consent purposes
    /// declared, the dialog comes first (once), and its cookie is set before any page loads.
    public func open(_ url: String) {
        guard let consent = session.consent else { return load(url) }
        consent.ask(from: presenter) { [weak self] in self?.load(url) }
    }

    private func load(_ url: String) {
        guard let target = URL(string: url) else { return }
        if origin.matches(target), let path = routePath(target), let screen = nativeScreen(path: path) {
            if webView.url == nil { webView.load(URLRequest(url: URL(string: home)!)) }
            present(screen, animated: true)
            return
        }
        webView.load(URLRequest(url: target))
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // Frames inside a page navigate within themselves; only the top level (or a new window) is policed.
        if let frame = action.targetFrame, !frame.isMainFrame { return decisionHandler(.allow) }
        let isSite = origin.matches(url)
        let path = routePath(url)
        if SignInRoute.isSignOut(method: action.request.httpMethod, isSite: isSite, path: path) {
            decisionHandler(.cancel)
            return signOut()
        }
        let screen = isSite ? path.flatMap { nativeScreen(path: $0) } : nil
        switch LinkPolicy.decide(scheme: url.scheme, isSite: isSite, isAuth: auth.matches(url), isNativeRoute: screen != nil, path: path,
                                  authSignInPaths: session.config.authSignInPaths) {
        case .loadInside:
            // A new window of the site's (`target="_blank"`) opens here: the app has one window.
            if action.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(action.request)
            } else {
                decisionHandler(.allow)
            }
        case .signIn:
            // NEVER SIGN IN IN THE WEB VIEW: the session is renewed, then the sign-in's `next` opens.
            decisionHandler(.cancel)
            let next = isSite ? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "next" }?.value : nil
            renewThen(SignInRoute.after(origin, next: next))
        case .openNative:
            decisionHandler(.cancel)
            // Back from the native screen lands on a page of the site, never on the account service's callback that redirected here.
            if !origin.matches(webView.url) { webView.load(URLRequest(url: URL(string: home)!)) }
            if let screen { present(screen, animated: true) }
        case .openOutside:
            decisionHandler(.cancel)
            openOutside(url)
        case .openIntent, .block:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if screen == .offlinePage { hidePanel() }
        failedURL = nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        guard origin.matches(webView.url) else { return }
        Task {
            if SessionCookies.isSignedIn(await session.cookies.jar()) { signedInPage() }
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        let failure = error as NSError
        // A navigation this class cancelled (a link handed out, a sign-in taken over) is not a failure.
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { return }
        if failure.domain == "WebKitErrorDomain" && failure.code == 102 { return }  // frame load interrupted by a policy change
        failedURL = failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if screen == nil { show(.offlinePage) }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    /// The page's process was reclaimed (memory) or crashed: the page is loaded again, never left blank.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil { webView.reload() } else { open(home) }
    }

    // MARK: - WKUIDelegate

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil  // handled as a navigation with no target frame, above
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard presentedViewController == nil else { return completionHandler() }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.text("shell_ok"), style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else { return completionHandler(false) }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.text("shell_cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: Strings.text("shell_ok"), style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    /// The site's pages do not stream the camera or the microphone.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - Links outside

    private func openOutside(_ url: URL) {
        UIApplication.shared.open(url) { [weak self] opened in
            guard !opened, let self, self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: nil, message: Strings.text("shell_no_app_for_link"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Strings.text("shell_ok"), style: .default))
            self.present(alert, animated: true)
        }
    }

    // MARK: - Sign-in, renewal and sign-out

    private func show(_ next: Screen) {
        screen = next
        let name = Strings.appName()
        switch next {
        case .working: panel.show(title: name, text: Strings.text("shell_signin_working"), button: nil)
        case .signingOut: panel.show(title: name, text: Strings.text("shell_signing_out"), button: nil)
        case .signIn: panel.show(title: name, text: Strings.text("shell_signin_text"), button: Strings.text("shell_signin_button"), link: privacyLink)
        case .failed: panel.show(title: name, text: Strings.text("shell_signin_failed"), button: Strings.text("shell_signin_button"), link: privacyLink)
        case .offlineSignIn: panel.show(title: name, text: Strings.text("shell_signin_offline"), button: Strings.text("shell_load_error_retry"))
        case .offlinePage:
            panel.show(title: Strings.text("shell_load_error_title"), text: Strings.text("shell_load_error_text"),
                       button: Strings.text("shell_load_error_retry"))
        case .askPush:
            panel.show(title: name, text: Strings.text("shell_push_text"), button: Strings.text("shell_push_continue"),
                       link: Strings.text("shell_push_later"))
        }
    }

    /// The privacy policy is a tap away before signing in too (App Review 5.1.1): the site's page, inside the app. From
    /// there a visitor reads the site's public pages; its sign-in links come back to the native sign-in.
    private var privacyLink: String? { session.config.privacyPath == nil ? nil : Strings.text("shell_privacy") }

    private func openPrivacy() {
        guard let url = origin.pageURL(session.config.privacyPath) else { return }
        hidePanel()
        open(url)
    }

    private func hidePanel() {
        screen = nil
        panel.isHidden = true
    }

    private func onPanelButton() {
        switch screen {
        case .offlineSignIn: renewThen(afterSignIn)
        case .signIn, .failed: startBrowserSignIn()
        case .offlinePage:
            hidePanel()
            webView.load(URLRequest(url: failedURL ?? URL(string: home)!))
        case .askPush:
            show(.working)
            Task {
                await session.push?.requestPermission()
                openAfterSignIn()
            }
        default: break
        }
    }

    private func onPanelLink() {
        if screen == .askPush {
            session.push?.markAsked()
            openAfterSignIn()
        } else {
            openPrivacy()
        }
    }

    /// THE SESSION IS LOST (the web view headed for a sign-in, or this start found no session of the site): renewed
    /// silently behind the progress, then [next]; the sign-in screen only when the account service refused the refresh.
    private func renewThen(_ next: String?) {
        afterSignIn = next ?? afterSignIn
        if screen == .working || signingOut { return }
        show(.working)
        Task {
            switch await session.keeper.renew(lostJar: await session.cookies.jar()) {
            case .renewed: sessionOpen(newSignIn: false)
            case .signIn:
                forgetLocalData()
                show(.signIn)
            case .offline: show(.offlineSignIn)
            }
        }
    }

    /// One button: the account service's sign-in sheet.
    private func startBrowserSignIn() {
        show(.working)
        Task {
            switch await browser.start(from: view.window) {
            case .cancelled: show(.signIn)
            case .failed: show(.failed)
            case .offline: show(.offlineSignIn)
            case let .done(renewal):
                switch renewal {
                case .renewed: sessionOpen(newSignIn: true)
                case .offline: show(.offlineSignIn)
                case .signIn: show(.failed)
                }
            }
        }
    }

    /// The site's session is in the store: the page asked for (or home), and the app's [afterNewSignIn]. Right after a
    /// new sign-in, notifications are asked once, with one sentence first (never at launch, never a condition).
    private func sessionOpen(newSignIn: Bool) {
        if newSignIn {
            replaceWebView()
            afterNewSignIn()
            if let push = session.push, !push.asked { return show(.askPush) }
        }
        openAfterSignIn()
    }

    private func openAfterSignIn() {
        hidePanel()
        let target = afterSignIn ?? home
        afterSignIn = nil
        open(target)
    }

    /// THE WEB'S SIGN-OUT, TAKEN OVER: the app's [beforeSignOut], then [AppSession.signOut] (the site's session ended
    /// while it still exists, the refresh token revoked at the account service, the tokens and cookies cleared), and the web's storage.
    /// The VougaDev session is not ended: the person's other applications stay signed in.
    private func signOut() {
        guard !signingOut else { return }
        signingOut = true
        show(.signingOut)
        beforeSignOut()
        Task {
            await session.signOut()
            await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            signingOut = false
            replaceWebView()
            afterSignIn = nil
            forgetLocalData()
            show(.signIn)
        }
    }

    private func signedInPage() {
        session.push?.refreshRegistration()
        session.extensions.forEach { $0.signedInPage(host: self) }
        onSignedInPage()
    }

    // MARK: - Notifications

    /// A tapped notification ([NotificationRoute]): a native screen an extension claims, this app's page, or another
    /// app's page through the system. Signed out or not ready yet, this app's page waits for the session.
    private func route(_ route: NotificationRoute) {
        switch route {
        case let .screen(key, fallback):
            if let claimed = session.extensions.lazy.compactMap({ $0.notificationScreen(key: key, url: fallback, host: self) }).first {
                presenter.present(claimed, animated: true)
            } else {
                openWhenReady(fallback?.absoluteString ?? home)
            }
        case let .page(url): openWhenReady(url.absoluteString)
        case let .outside(url): UIApplication.shared.open(url)
        case .home: openWhenReady(home)
        }
    }

    private func openWhenReady(_ url: String) {
        if booted && screen == nil { open(url) } else { afterSignIn = url }
    }

    // MARK: - The core's members

    private func coreMethods() -> [(String, NativeBridge.Method)] {
        [
            ("openSettings", { [weak self] _, answer in
                guard let self else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                self.openSettings()
                answer(NativeBridge.ok())
            }),
            ("consent", { [weak self] _, answer in
                answer(self?.session.consent?.state() ?? ["asked": false, "choices": [String: Bool]()])
            }),
        ]
    }

    /// The app's native Settings ([SettingsViewController]).
    public func openSettings() {
        let settings = SettingsViewController(session: session, openPage: { [weak self] in self?.open($0) },
                                              signOut: { [weak self] in self?.signOut() })
        presenter.present(UINavigationController(rootViewController: settings), animated: true)
    }
}

/// The reply handler, holding the controller's bridge but not the controller (WebKit keeps its handlers strongly).
private final class BridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    let bridge: NativeBridge

    init(_ bridge: NativeBridge) { self.bridge = bridge }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        bridge.onMessage(message.body, isMainFrame: message.frameInfo.isMainFrame, scheme: origin.protocol, host: origin.host,
                         port: origin.port) { replyHandler($0, nil) }
    }
}
