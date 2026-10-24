import AuthenticationServices
import UIKit

/// THE APP'S SIGN-IN with the account service: the authorization code flow with PKCE S256 for the app's public client,
/// then the code exchange; the tokens go to the [SessionKeeper]. The code arrives from the web view (the account
/// service's page calls `completeSignIn`, or redirects to the app's address) or, as the fallback while the account
/// service cannot finish it through the bridge, from the system sign-in sheet (`ASWebAuthenticationSession`).
///
/// The ID token is not read: the app uses only the access token, as a bearer the site checks with the account service itself.
@MainActor
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum Outcome: Equatable {
        case done(Renewal)
        /// The person closed the sheet: nothing happened.
        case cancelled
        case failed
        /// The account service's discovery or token endpoint out of reach.
        case offline
    }

    private let session: AppSession
    private var running: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    init(session: AppSession) { self.session = session }

    /// The account service's authorization address for a new sign-in, with its PKCE request; nil when the account
    /// service cannot be reached.
    func prepare() async -> (url: URL, request: AuthorizeRequest)? {
        guard let discovery = await session.discovery() else { return nil }
        let request = AuthorizeRequest()
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        guard let url = request.url(discovery: discovery, client: session.client, scopes: session.config.scopes, uiLocales: locale) else {
            return nil
        }
        return (url, request)
    }

    /// The code the account service gave this sign-in, traded with its verifier for the app's tokens, then the site's session.
    func exchange(code: String, request: AuthorizeRequest) async -> Outcome {
        switch await session.endpoints.exchange(code: code, verifier: request.verifier) {
        case let .tokens(access, refresh): return .done(await session.keeper.signedIn(accessToken: access, refreshToken: refresh))
        case .refused: return .failed
        case .unreachable: return .offline
        }
    }

    /// The fallback while the account service cannot finish the sign-in through the bridge: the system sign-in sheet.
    func start(from window: UIWindow?) async -> Outcome {
        guard running == nil else { return .cancelled }
        guard let (url, request) = await prepare() else { return .offline }
        anchor = window
        let callback: URL? = await withCheckedContinuation { done in
            var finished = false
            let finish = { (url: URL?) in
                guard !finished else { return }
                finished = true
                done.resume(returning: url)
            }
            let sheet = ASWebAuthenticationSession(url: url, callbackURLScheme: session.client.callbackScheme) { url, _ in finish(url) }
            sheet.presentationContextProvider = self
            sheet.prefersEphemeralWebBrowserSession = false
            running = sheet
            if !sheet.start() { finish(nil) }
        }
        running = nil
        // A closed sheet answers no URL; any other error (none to tell apart for the person) is the same: sign in again.
        guard let callback else { return .cancelled }
        guard case let .code(code) = request.read(callback: callback, client: session.client) else { return .failed }
        return await exchange(code: code, request: request)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? ASPresentationAnchor() }
    }
}
