import AuthenticationServices
import UIKit

/// `VougaDevNative.nativeSignIn("apple" | "google")`: the logins of other companies, which refuse web views, through the
/// phone's own sheets; the identity token goes back to the account service's page that asked, which checks it.
///
/// - **apple**: Sign in with Apple's native sheet (`ASAuthorizationAppleIDProvider`); needs the app's "Sign in with
///   Apple" capability.
/// - **google**: Google's sign-in for iOS apps in the system sheet, with the app's Google client for iOS
///   (`ShellConfig.googleClientID`), PKCE and the client's reversed id as its return address.
///
/// The page may pass a `nonce`, put as it is in the token for its check. Answers
/// `{ok: true, provider, idToken, authorizationCode?, email?, name?}` or `{ok: false, error}`: `cancelled`,
/// `unavailable` (not set up in this app), `failed`.
@MainActor
final class NativeSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding,
                          ASWebAuthenticationPresentationContextProviding {

    private weak var window: UIWindow?
    private let googleClientID: String?
    private let transport: HttpTransport
    private var appleAnswer: ((JSONObject) -> Void)?
    private var running: ASWebAuthenticationSession?

    init(googleClientID: String?, transport: HttpTransport) {
        self.googleClientID = googleClientID
        self.transport = transport
    }

    func start(_ args: JSONObject?, window: UIWindow?, answer: @escaping (JSONObject) -> Void) {
        self.window = window
        let provider = (args?["provider"] as? String) ?? (args?["value"] as? String) ?? ""
        let nonce = args?["nonce"] as? String
        switch provider {
        case "apple": apple(nonce: nonce, answer: answer)
        case "google": Task { answer(await google(nonce: nonce)) }
        default: answer(NativeBridge.refused("unavailable"))
        }
    }

    // MARK: - Apple

    private func apple(nonce: String?, answer: @escaping (JSONObject) -> Void) {
        guard appleAnswer == nil else { return answer(NativeBridge.refused("failed")) }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce
        appleAnswer = answer
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential?.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0) }
        let email = credential?.email
        MainActor.assumeIsolated {
            guard let token else { return self.finishApple(NativeBridge.refused("failed")) }
            var answer: JSONObject = ["ok": true, "provider": "apple", "idToken": token]
            if let code { answer["authorizationCode"] = code }
            if let email { answer["email"] = email }
            if let name, !name.isEmpty { answer["name"] = name }
            self.finishApple(answer)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let code = (error as? ASAuthorizationError)?.code
        MainActor.assumeIsolated {
            // Without the capability (or on a phone with no Apple account) the sheet cannot open: not set up here.
            self.finishApple(NativeBridge.refused(code == .canceled ? "cancelled" : code == .unknown || code == .notHandled ? "unavailable" : "failed"))
        }
    }

    private func finishApple(_ answer: JSONObject) {
        appleAnswer?(answer)
        appleAnswer = nil
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? ASPresentationAnchor() }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { window ?? ASPresentationAnchor() }
    }

    // MARK: - Google

    /// `com.googleusercontent.apps.<id>` for the client `<id>.apps.googleusercontent.com`: the return address Google
    /// gives an iOS client.
    nonisolated static func googleScheme(_ clientID: String) -> String {
        "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    nonisolated static func googleAuthorizeURL(clientID: String, request: AuthorizeRequest, nonce: String?) -> URL? {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        parts?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: googleScheme(clientID) + ":/oauth2redirect"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: request.state),
            URLQueryItem(name: "nonce", value: nonce ?? request.nonce),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: request.verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return parts?.url
    }

    private func google(nonce: String?) async -> JSONObject {
        guard let clientID = googleClientID, !clientID.isEmpty else { return NativeBridge.refused("unavailable") }
        guard running == nil else { return NativeBridge.refused("failed") }
        let request = AuthorizeRequest()
        let redirect = Self.googleScheme(clientID) + ":/oauth2redirect"
        guard let url = Self.googleAuthorizeURL(clientID: clientID, request: request, nonce: nonce) else { return NativeBridge.refused("failed") }
        let callback: URL? = await withCheckedContinuation { done in
            var finished = false
            let finish = { (url: URL?) in
                guard !finished else { return }
                finished = true
                done.resume(returning: url)
            }
            let sheet = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.googleScheme(clientID)) { url, _ in finish(url) }
            sheet.presentationContextProvider = self
            running = sheet
            if !sheet.start() { finish(nil) }
        }
        running = nil
        guard let callback else { return NativeBridge.refused("cancelled") }
        let client = AuthClient(issuer: "https://accounts.google.com", clientID: clientID, redirectURI: redirect)
        guard case let .code(code) = request.read(callback: callback, client: client),
              let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else { return NativeBridge.refused("failed") }
        let form = AuthEndpoints.formRequest(tokenURL, [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("client_id", clientID),
            ("code_verifier", request.verifier),
        ])
        guard let (data, response) = try? await transport.send(form), response.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let token = json["id_token"] as? String else { return NativeBridge.refused("failed") }
        return ["ok": true, "provider": "google", "idToken": token]
    }
}
