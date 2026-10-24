import UIKit
import VougaDevShell

/// THE `tracking` EXTENSION: a started mission's position shared with the site, in the background too, after its own
/// disclosure ([TrackingDisclosure]). Its members of `window.VougaDevNative`:
///
/// ```
/// startTracking({missionId, url?, intervalSeconds?, target?, title?, text?}) -> Promise<{ok: true} | {ok: false, error}>
/// stopTracking()                                                            -> Promise<{ok: true}>
/// trackingState()                                                           -> Promise<{active, missionId, lastSentAt, lastError}>
/// ```
///
/// Needs `UIBackgroundModes = [location]`, `NSLocationWhenInUseUsageDescription` and
/// `NSLocationTemporaryUsageDescriptionDictionary.Tracking` (never "Always").
@MainActor
public final class TrackingExtension: ShellExtension {

    public let name = "tracking"
    public let paths: TrackingPaths
    /// Made when the session attaches: it keeps its state in the app's defaults and posts as the web view's session.
    public private(set) var service: TrackingService!
    private var flow: TrackingStartFlow?
    private var followed = false

    public init(paths: TrackingPaths) { self.paths = paths }

    public func attach(to session: AppSession) {
        service = TrackingService(store: TrackingStore(defaults: session.defaults, paths: paths),
                                  disclosure: TrackingDisclosure(defaults: session.defaults),
                                  caller: { [unowned session] in session.caller() })
    }

    public var requirements: ShellRequirements {
        ShellRequirements(purposeStrings: ["NSLocationWhenInUseUsageDescription"], backgroundModes: ["location"],
                          temporaryLocationPurposes: [TrackingService.precisePurposeKey])
    }

    public func bridgeMethods(host: ShellHost) -> [(String, NativeBridge.Method)] {
        [
            ("startTracking", { [weak self, weak host] args, answer in
                guard let self, let host else { return answer(NativeBridge.refused(NativeShim.errorUnavailable)) }
                switch TrackingRequest.parse(args, paths: self.paths) {
                case let .refused(reason): answer(NativeBridge.refused(reason))
                case let .accepted(request):
                    self.startFlow(host).submit(request) { error in answer(error.map(NativeBridge.refused) ?? NativeBridge.ok()) }
                }
            }),
            ("stopTracking", { [weak self] _, answer in
                self?.service.stop()
                answer(NativeBridge.ok())
            }),
            ("trackingState", { [weak self] _, answer in answer(self?.service.state() ?? NativeBridge.refused("state_unreadable")) }),
        ]
    }

    private func startFlow(_ host: ShellHost) -> TrackingStartFlow {
        if let flow { return flow }
        let made = TrackingStartFlow(phone: LocationPhone(service: service, presenter: host.presenter))
        flow = made
        return made
    }

    /// THE MISSION TO SHARE THE POSITION FOR, asked once per sign-in ([TrackingTarget]): a started mission the server
    /// names is tracked (when precise location is held and on), tracking the server no longer has a mission for stops.
    /// A person who is not a courier is answered 404, and nothing happens.
    public func signedInPage(host: ShellHost) {
        guard !followed else { return }
        followed = true
        Task {
            if case let .ok(body) = await host.session.caller().get(paths.target) { await service.follow(body) }
        }
    }

    public func becameActive(host: ShellHost) { service.resumeIfPending() }

    public func signOut() async {
        flow?.abandon()
        flow = nil
        followed = false
        service.forget()
    }
}

/// The extension's resource bundle (the disclosure's texts), for tests and tools.
public enum TrackingResources {
    public static let bundle = Bundle.module
}
