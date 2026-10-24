import AuthenticationServices
import UIKit

/// AN OUTSIDE STEP THAT MUST LEAVE THE WEB VIEW (a payment provider that refuses web views: PayPal, a bank page that
/// will not run inside), and comes back by itself: `openOutside({url, returnUrl})` from the payment service's page, or
/// a navigation to one of `ShellConfig.outsideHosts`.
///
/// The step opens in the system sheet over the app (`ASWebAuthenticationSession`). When it reaches an address under the
/// return prefix (`ShellConfig.outsideReturnPrefix`, e.g. `https://pay.example.org/app-return/`), the sheet closes and
/// that address loads in the web view. The sheet waits for it as an https callback (iOS 17.4, with the payment domain
/// associated to the app) or, as the fallback, for `vougadev-return://app-return?url=<the return address>`, which the
/// return page sends when it opens outside the app. Answers `ok` with the return address, `cancelled` when the person
/// closed the sheet, `failed` when no sheet could open, `invalid_url` for a `url` not https or a `returnUrl` outside
/// the prefix.
@MainActor
final class OutsideStep: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let fallbackScheme = "vougadev-return"

    enum Outcome: Equatable {
        case returned(URL)
        case cancelled, failed, invalidURL

        var error: String? {
            switch self {
            case .returned: return nil
            case .cancelled: return "cancelled"
            case .failed: return "failed"
            case .invalidURL: return "invalid_url"
            }
        }
    }

    private weak var window: UIWindow?
    private var running: ASWebAuthenticationSession?

    /// The step's address and where it returns, checked: [url] https; [returnURL] (or the prefix itself) under [prefix].
    nonisolated static func check(url: String?, returnURL: String?, prefix: String?) -> (URL, URL)? {
        guard let prefix, let base = URL(string: prefix), base.scheme == "https",
              let url = url.flatMap(URL.init(string:)), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        let back = returnURL ?? prefix
        guard back.hasPrefix(prefix), let target = URL(string: back), target.host == base.host else { return nil }
        return (url, target)
    }

    /// The return address the sheet came back with: the https callback itself, or the fallback's `url`, either under [prefix].
    nonisolated static func returned(_ callback: URL?, prefix: String) -> URL? {
        guard let callback else { return nil }
        if callback.scheme == fallbackScheme {
            let raw = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            return raw.flatMap { $0.hasPrefix(prefix) ? URL(string: $0) : nil }
        }
        return callback.absoluteString.hasPrefix(prefix) ? callback : nil
    }

    func open(_ url: URL, returnTo target: URL, prefix: String, window: UIWindow?) async -> Outcome {
        guard running == nil else { return .failed }
        self.window = window
        let callback: (URL?, Bool) = await withCheckedContinuation { done in
            var finished = false
            let finish = { (url: URL?, cancelled: Bool) in
                guard !finished else { return }
                finished = true
                done.resume(returning: (url, cancelled))
            }
            let handler: ASWebAuthenticationSession.CompletionHandler = { url, error in
                finish(url, (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin)
            }
            let sheet: ASWebAuthenticationSession
            if #available(iOS 17.4, *), Self.associated(target.host) {
                sheet = ASWebAuthenticationSession(url: url, callback: .https(host: target.host ?? "", path: target.path), completionHandler: handler)
            } else {
                sheet = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.fallbackScheme, completionHandler: handler)
            }
            sheet.presentationContextProvider = self
            sheet.prefersEphemeralWebBrowserSession = false
            running = sheet
            if !sheet.start() { finish(nil, false) }
        }
        running = nil
        if let back = Self.returned(callback.0, prefix: prefix) { return .returned(back) }
        return callback.1 ? .cancelled : .failed
    }

    /// An https callback needs the domain associated with the app (`webcredentials:` in its entitlements, and the
    /// domain's apple-app-site-association naming the app's Team ID); the app says so in Info.plist
    /// (`VougaDevAssociatedDomains`), else the fallback scheme is used.
    nonisolated static func associated(_ host: String?) -> Bool {
        guard let host else { return false }
        return (Bundle.main.object(forInfoDictionaryKey: "VougaDevAssociatedDomains") as? [String])?.contains(host) == true
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? ASPresentationAnchor() }
    }
}
