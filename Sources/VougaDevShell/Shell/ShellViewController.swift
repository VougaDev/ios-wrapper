import SafariServices
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
    private lazy var panel = ShellPanel(colors: session.config.colors, titleFont: session.config.titleFont)
    private lazy var browser = BrowserSignIn(session: session)
    private lazy var nativeSignIn = NativeSignIn(googleClientID: session.config.googleClientID, transport: session.transport)
    /// The company's other origins with the payment members (`ShellConfig.trustedOrigins`).
    private lazy var payment: [AppOrigin] = session.config.trustedOrigins.map(AppOrigin.init)
    /// Every origin whose pages get the bridge: the site's, the account service's, the payment service's.
    private lazy var trusted: [AppOrigin] = [origin, auth] + payment
    private lazy var outsideStep = OutsideStep()
    /// The sign-in running in the web view: its PKCE request, until the account service hands the code back.
    private var pendingSignIn: AuthorizeRequest?
    /// The MIME type of the last main-frame answer: only an HTML page is checked for the site's marker.
    private var mainMIME: String?
    private enum Screen { case working, signingOut, signIn, failed, offlineSignIn, offlineMissing, offlineWelcome, askPush }

    private var screen: Screen?
    /// The page to open once the session is open (the sign-in's `next`).
    private var afterSignIn: String?
    private var signingOut = false
    /// The URL whose main-frame load failed, reloaded by Try again.
    private var failedURL: URL?
    private var booted = false
    private lazy var network = NetworkWatch(simulatedOffline: session.config.simulateOffline)
    private lazy var offlineBar = OfflineBar(colors: session.config.colors)
    /// The real address of the page shown from the phone (no network); nil when the page came from the network.
    private var showingKept: URL?
    /// A kept page is being loaded into the web view (the navigation is the app's own, never refused).
    private var loadingKept = false
    /// The status of the last main-frame answer: only a 200 is kept.
    private var mainStatus: Int?
    private var firstPageShown = false

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
        offlineBar.isHidden = true
        offlineBar.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(offlineBar, belowSubview: panel)
        NSLayoutConstraint.activate([
            offlineBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offlineBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            offlineBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        network.onChange = { [weak self] online in self?.networkChanged(online) }
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !booted else { return }
        booted = true
        boot()
    }

    /// This start's first screen. Never signed in on this phone: the sign-in screen (cookies left by anything else are
    /// not the app's, they go); with no network, the pages kept from an earlier visit, else the app's welcome. Signed in
    /// but the site's session gone: renewed first. Else the home page, or with no network the last page kept.
    private func boot() {
        Task {
            let online = await network.current()
            guard session.signedIn else {
                await session.cookies.clear()
                forgetLocalData()
                if !online, let last = session.offlinePages.entries.first { return showKept(last) }
                return show(online ? .signIn : .offlineWelcome)
            }
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
        // The site's own origin every member; the account service's its sign-in; the payment service's (its frames too)
        // the outside step.
        let roles = [NativeShim.Role(origin: origin, members: methods.map { $0.0 }),
                     NativeShim.Role(origin: auth, members: ["completeSignIn", "nativeSignIn"])]
            + payment.map { NativeShim.Role(origin: $0, members: ["openOutside"], frames: true) }
        let bridge = NativeBridge(roles: roles, methods: Dictionary(methods, uniquingKeysWith: { first, _ in first }))
        let script = NativeShim.script(roles: roles, version: session.config.versionName, features: session.features)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        // The account service's answer to a sign-in in the web view: its redirect to the app's own address.
        if pendingSignIn != nil, url.absoluteString.hasPrefix(session.config.redirectURI) {
            decisionHandler(.cancel)
            let request = pendingSignIn
            if case let .code(code) = request?.read(callback: url, client: session.client) {
                Task { _ = await completeWebSignIn(code: code, state: request?.state) }
            } else {
                pendingSignIn = nil
                show(.failed)
            }
            return
        }
        // A provider that refuses web views (PayPal), reached from a company page: an outside step that comes back.
        if (action.targetFrame?.isMainFrame ?? true), session.config.outsideReturnPrefix != nil,
           LinkPolicy.isCompany(host: url.host, domains: session.config.outsideHosts) {
            decisionHandler(.cancel)
            Task { _ = await runOutside(url: url.absoluteString, returnURL: nil) }
            return
        }
        let isSite = origin.matches(url)
        let path = routePath(url)
        if SignInRoute.isSignOut(method: action.request.httpMethod, isSite: isSite, path: path) {
            decisionHandler(.cancel)
            return signOut()
        }
        let screen = isSite ? path.flatMap { nativeScreen(path: $0) } : nil
        let isCompany = LinkPolicy.isCompany(host: url.host, domains: session.config.companyDomains)
        switch LinkPolicy.decide(scheme: url.scheme, isSite: isSite, isAuth: auth.matches(url), isCompany: isCompany,
                                  isNativeRoute: screen != nil, path: path, authSignInPaths: session.config.authSignInPaths,
                                  signInInWebView: session.config.signInInWebView) {
        case .loadInside:
            // The UI tests' "no network": a page of the network is never loaded, as in airplane mode.
            if session.config.simulateOffline && !loadingKept {
                decisionHandler(.cancel)
                return offlineFallback(url)
            }
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
        case .openSheet:
            // An outside company's site: an in-app sheet over the app, which closes back to it.
            decisionHandler(.cancel)
            let sheet = SFSafariViewController(url: url)
            sheet.preferredControlTintColor = session.config.colors.accent
            sheet.dismissButtonStyle = .done
            presenter.present(sheet, animated: true)
        case .openOutside:
            decisionHandler(.cancel)
            openOutside(url)
        case .openIntent, .block:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { return decisionHandler(.allow) }
        let response = navigationResponse.response
        mainMIME = response.mimeType
        mainStatus = (response as? HTTPURLResponse)?.statusCode
        // NEVER A RAW ERROR PAGE: the edge's or a CDN's failure on a company page is answered as with no network.
        let company = response.url.map { url in
            trusted.contains { $0.matches(url) } || LinkPolicy.isCompany(host: url.host, domains: session.config.companyDomains)
        } ?? false
        if company, !loadingKept {
            if let simulated = session.config.simulatedEdgeStatus { mainStatus = simulated }
            if let status = mainStatus, Self.isEdgeError(status) {
                decisionHandler(.cancel)
                return offlineFallback(response.url)
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if screen == .offlineMissing || screen == .offlineWelcome { hidePanel() }
        failedURL = nil
        firstPageShown = true
        if loadingKept {
            loadingKept = false
        } else {
            showingKept = nil
            offlineBar.isHidden = true
        }
    }

    /// The statuses an edge or a CDN answers with when the site could not: 502, 503, 504, and a CDN's own 520–530.
    nonisolated static func isEdgeError(_ status: Int) -> Bool { [502, 503, 504].contains(status) || (520...530).contains(status) }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        notifyNetwork()
        guard let url = webView.url else { return }
        let config = session.config
        // A company page of the site's or the payment service's origin carries the company's meta (or the site's older
        // marker): without it, it is an edge's or a CDN's error page, never shown.
        if showingKept == nil, config.requirePageMeta || config.siteMarker != nil, mainMIME == "text/html",
           origin.matches(url) || payment.contains(where: { $0.matches(url) }) {
            let marker = config.siteMarker.map { "document.documentElement.outerHTML.indexOf(\(NativeShim.quote($0))) >= 0" } ?? "false"
            let check = "!!document.querySelector('meta[name=\"vougadev-page\"]') || \(marker)"
            webView.evaluateJavaScript(check) { [weak self] found, _ in
                guard let self else { return }
                if (found as? Bool) == false { return self.offlineFallback(url) }
                if self.origin.matches(url) { self.siteFinished(webView) }
            }
            return
        }
        if origin.matches(url) { siteFinished(webView) }
    }

    private func siteFinished(_ webView: WKWebView) {
        // A page of the site from the network, answered 200: kept for when there is no network.
        if showingKept == nil, mainStatus == 200, let url = webView.url, routePath(url)?.hasPrefix("/auth/") == false {
            Task { await session.offlinePages.save(webView, url: url) }
        }
        guard showingKept == nil else { return }
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
        loadingKept = false
        offlineFallback(failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    // MARK: - No network

    /// A page that could not load: its kept copy; at launch the last page kept; else what is kept, or the welcome when
    /// nothing is. Never a dead end (App Review 4.2).
    private func offlineFallback(_ url: URL?) {
        let pages = session.offlinePages
        if let url, let kept = pages.entry(for: url) { return showKept(kept) }
        if !firstPageShown, let last = pages.entries.first { return showKept(last) }
        failedURL = url
        show(pages.entries.isEmpty ? .offlineWelcome : .offlineMissing)
    }

    /// A kept page in the web view, at its own address (the bridge and the page's scripts see the site's origin), under
    /// the "Offline · updated at" bar.
    private func showKept(_ entry: OfflinePages.Entry) {
        guard let url = URL(string: entry.url), let data = session.offlinePages.archive(entry) else {
            return show(session.offlinePages.entries.isEmpty ? .offlineWelcome : .offlineMissing)
        }
        hidePanel()
        showingKept = url
        loadingKept = true
        offlineBar.show(savedAt: entry.savedAt)
        webView.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: url)
    }

    /// The kept pages, newest first, as choices.
    private func keptRows() -> [(String, () -> Void)] {
        session.offlinePages.entries.prefix(6).map { entry in
            // Never an address on screen: a page without a title is "the home page" or the app's name.
            let path = URL(string: entry.url).flatMap(routePath)
            let label = !entry.title.isEmpty ? entry.title : path == "/" ? Strings.text("shell_offline_home") : Strings.appName()
            return (label, { [weak self] in self?.showKept(entry) })
        }
    }

    /// The network came back: the page shown from the phone is fetched again, a waiting screen goes on; it went: pages
    /// are told.
    private func networkChanged(_ online: Bool) {
        notifyNetwork()
        guard online else { return }
        if let kept = showingKept {
            webView.load(URLRequest(url: kept))
            return
        }
        switch screen {
        case .offlineWelcome: boot()
        case .offlineMissing:
            hidePanel()
            webView.load(URLRequest(url: failedURL ?? URL(string: home)!))
        case .offlineSignIn: renewThen(afterSignIn)
        default: break
        }
    }

    /// `network()` and the `vougadev:network` event: `{online, offlinePage, savedAt}` (`savedAt` in ms, or null).
    private func networkState() -> JSONObject {
        let saved = showingKept.flatMap { session.offlinePages.entry(for: $0)?.savedAt }
        return ["online": network.online, "offlinePage": showingKept != nil,
                "savedAt": saved.map { NSNumber(value: Int64($0.timeIntervalSince1970 * 1000)) } ?? NSNull()]
    }

    private func notifyNetwork() {
        guard origin.matches(webView.url) else { return }
        let detail = NativeBridge.text(networkState())
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('vougadev:network', { detail: \(detail) }));")
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
        let mark = session.config.mark
        switch next {
        case .working: panel.show(title: name, text: Strings.text("shell_signin_working"), button: nil, image: mark, brand: true)
        case .signingOut: panel.show(title: name, text: Strings.text("shell_signing_out"), button: nil, image: mark, brand: true)
        case .signIn:
            panel.show(title: name, text: Strings.text("shell_signin_text"), button: Strings.text("shell_signin_button"),
                       link: privacyLink, image: mark, brand: true)
        case .failed:
            panel.show(title: name, text: Strings.text("shell_signin_failed"), button: Strings.text("shell_signin_button"),
                       link: privacyLink, image: mark, brand: true)
        case .offlineSignIn:
            let rows = keptRows()
            panel.show(title: name, text: Strings.text(rows.isEmpty ? "shell_signin_offline" : "shell_signin_offline_kept"),
                       button: Strings.text("shell_load_error_retry"), image: mark, brand: true, rows: rows)
        case .offlineMissing:
            panel.show(title: Strings.text("shell_offline_missing_title"), text: Strings.text("shell_offline_missing_text"),
                       button: Strings.text("shell_load_error_retry"), link: Strings.text("shell_back"),
                       image: UIImage(systemName: "wifi.slash"), rows: keptRows())
        case .offlineWelcome:
            panel.show(title: name, text: Strings.text("shell_offline_welcome"), button: nil, image: mark, brand: true, busy: false)
        case .askPush:
            panel.show(title: name, text: Strings.text("shell_push_text"), button: Strings.text("shell_push_continue"),
                       link: Strings.text("shell_push_later"), image: UIImage(systemName: "bell.badge"))
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
        case .offlineMissing:
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
        if screen == .offlineMissing {
            // Back to what was shown before, or the newest page kept.
            if webView.canGoBack, webView.url != nil {
                hidePanel()
                webView.goBack()
            } else if let last = session.offlinePages.entries.first {
                showKept(last)
            }
        } else if screen == .askPush {
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
            case .offline:
                // No network: the page asked for (or the last one) from the phone, else the sign-in's own message.
                if let kept = self.afterSignIn.flatMap(URL.init(string:)).flatMap({ self.session.offlinePages.entry(for: $0) })
                    ?? (self.firstPageShown ? nil : self.session.offlinePages.entries.first) {
                    self.showKept(kept)
                } else {
                    self.show(.offlineSignIn)
                }
            }
        }
    }

    /// One button: the account service's sign-in, in the web view (finished by `completeSignIn` or the redirect), or in
    /// the system sheet until the account service calls the shell; with no network, the sign-in says so (and offers what
    /// is kept).
    private func startBrowserSignIn() {
        guard network.online else { return show(.offlineSignIn) }
        show(.working)
        if session.config.signInInWebView {
            Task {
                guard let (url, request) = await browser.prepare() else { return show(.offlineSignIn) }
                pendingSignIn = request
                hidePanel()
                webView.load(URLRequest(url: url))
            }
            return
        }
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

    /// AN OUTSIDE STEP ([OutsideStep]): the sheet over the app; its return address loads in the web view.
    private func runOutside(url: String?, returnURL: String?) async -> JSONObject {
        guard let prefix = session.config.outsideReturnPrefix,
              let (step, target) = OutsideStep.check(url: url, returnURL: returnURL, prefix: prefix) else {
            return NativeBridge.refused("invalid_url")
        }
        switch await outsideStep.open(step, returnTo: target, prefix: prefix, window: view.window) {
        case let .returned(back):
            webView.load(URLRequest(url: back))
            return NativeBridge.ok()
        case let other:
            return NativeBridge.refused(other.error ?? "failed")
        }
    }

    /// The account service's code for the sign-in running in the web view, by `completeSignIn` or its redirect.
    private func completeWebSignIn(code: String?, state: String?) async -> JSONObject {
        guard let request = pendingSignIn, let code, !code.isEmpty, state == request.state else { return NativeBridge.refused("invalid_state") }
        pendingSignIn = nil
        show(.working)
        switch await browser.exchange(code: code, request: request) {
        case let .done(renewal):
            switch renewal {
            case .renewed:
                sessionOpen(newSignIn: true)
                return NativeBridge.ok()
            case .offline:
                show(.offlineSignIn)
                return NativeBridge.refused("offline")
            case .signIn:
                show(.failed)
                return NativeBridge.refused("exchange_refused")
            }
        case .offline:
            show(.offlineSignIn)
            return NativeBridge.refused("offline")
        case .cancelled, .failed:
            show(.failed)
            return NativeBridge.refused("exchange_refused")
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
            ("completeSignIn", { [weak self] args, answer in
                guard let self else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                Task { answer(await self.completeWebSignIn(code: args?["code"] as? String, state: args?["state"] as? String)) }
            }),
            ("nativeSignIn", { [weak self] args, answer in
                guard let self else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                self.nativeSignIn.start(args, window: self.view.window, answer: answer)
            }),
            ("openOutside", { [weak self] args, answer in
                guard let self else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                Task { answer(await self.runOutside(url: args?["url"] as? String, returnURL: args?["returnUrl"] as? String)) }
            }),
            ("network", { [weak self] _, answer in
                answer(self?.networkState() ?? ["online": true, "offlinePage": false, "savedAt": NSNull()])
            }),
            ("consent", { [weak self] _, answer in
                answer(self?.session.consent?.state() ?? [:])
            }),
        ]
    }

    /// The app's native Settings ([SettingsViewController]).
    public func openSettings() {
        let settings = SettingsViewController(session: session, host: self, openPage: { [weak self] in self?.open($0) },
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
