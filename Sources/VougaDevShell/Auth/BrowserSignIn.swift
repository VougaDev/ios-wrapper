import AuthenticationServices
import UIKit

/// SIGN-IN IN THE SYSTEM'S SIGN-IN SHEET (`ASWebAuthenticationSession`, "<App> wants to use <sign-in domain> to sign
/// in"), never in the web view: the authorization code flow with PKCE S256 for the app's public client, then the code
/// exchange. The tokens go to the [SessionKeeper]. The sheet shares Safari's cookies (not ephemeral), so a person
/// already signed in to VougaDev in Safari only confirms.
///
/// The ID token is not read: the app uses only the access token, as a bearer the site checks with the account service itself.
@MainActor
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum Outcome: Equatable {
        case done(Renewal)
        /// The person closed the sheet: nothing happened.
        case cancelled
        case failed
        /// the account service's discovery or token endpoint out of reach.
        case offline
    }

    private let session: AppSession
    private var running: ASWebAuthenticationSession?
    private weak var anchor: UIWindow?

    init(session: AppSession) { self.session = session }

    func start(from window: UIWindow?) async -> Outcome {
        guard running == nil else { return .cancelled }
        guard let discovery = await session.discovery() else { return .offline }
        let request = AuthorizeRequest()
        let locale = Locale.current.language.languageCode?.identifier ?? "en"
        guard let url = request.url(discovery: discovery, client: session.client, scopes: session.config.scopes, uiLocales: locale) else {
            return .failed
        }
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
        switch await session.endpoints.exchange(code: code, verifier: request.verifier) {
        case let .tokens(access, refresh): return .done(await session.keeper.signedIn(accessToken: access, refreshToken: refresh))
        case .refused: return .failed
        case .unreachable: return .offline
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? ASPresentationAnchor() }
    }
}
