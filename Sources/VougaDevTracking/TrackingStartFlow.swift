import CoreLocation
import UIKit
import VougaDevShell

/// What the start flow needs of the phone; [LocationPhone] in the app, a fake in the tests. Every `then` is called on
/// the main thread, once, after the person answered.
@MainActor
public protocol TrackingPhone: AnyObject {
    /// The disclosure ([TrackingDisclosure]): true at once when already agreed.
    func disclose(_ then: @escaping (Bool) -> Void)
    /// Location Services switched on for the phone.
    func locationOn(_ then: @escaping (Bool) -> Void)
    var hasPreciseLocation: Bool { get }
    var hasApproximateLocation: Bool { get }
    /// The system's "While Using the App" dialog, or, with approximate location only, its precise-location one.
    func askLocation(_ then: @escaping () -> Void)
    func start(_ request: TrackingRequest)
    /// `trackingState().lastError` for a start refused before tracking existed.
    func recordRefusal(_ missionID: String, error: String)
}

/// What `VougaDevNative.startTracking` does before tracking starts, in the order the person sees it - the page's Promise
/// resolves only once they answered:
///
/// 0. The disclosure, until agreed: declined -> `tracking_declined`.
/// 1. Location Services off -> `location_disabled` (the system shows no permission dialog while they are off, so this
///    platform checks them first; nothing else needs switching on).
/// 2. Location permission. With approximate only, the precise dialog is shown ONCE more; still no precise ->
///    `location_permission_denied` (tracking needs GPS-grade fixes).
///
/// No notification permission is asked: the system's location indicator shows the sharing. One start at a time: a
/// second call while the first is waiting for the person is queued and runs after it.
@MainActor
public final class TrackingStartFlow {

    private final class Call {
        let request: TrackingRequest
        let answer: (String?) -> Void

        init(_ request: TrackingRequest, _ answer: @escaping (String?) -> Void) {
            self.request = request
            self.answer = answer
        }
    }

    let phone: TrackingPhone
    private var queue: [Call] = []
    private var running: Call?

    public init(phone: TrackingPhone) { self.phone = phone }

    /// [answer] gets nil once tracking started, or the refusal code.
    public func submit(_ request: TrackingRequest, answer: @escaping (String?) -> Void) {
        queue.append(Call(request, answer))
        runNext()
    }

    /// Signing out: nobody is left to answer, nor to show a dialog to.
    public func abandon() {
        queue.removeAll()
        running = nil
    }

    private func runNext() {
        guard running == nil, !queue.isEmpty else { return }
        let call = queue.removeFirst()
        running = call
        phone.disclose { [self] agreed in
            agreed ? locationSwitch(call) : refuse(call, TrackingService.errorDeclined)
        }
    }

    private func locationSwitch(_ call: Call) {
        phone.locationOn { [self] on in
            on ? locationPermission(call) : refuse(call, TrackingService.errorLocationDisabled)
        }
    }

    private func locationPermission(_ call: Call) {
        if phone.hasPreciseLocation { return begin(call) }
        // Approximate already held: this first dialog IS the precise one, and is not repeated.
        let approximateBefore = phone.hasApproximateLocation
        phone.askLocation { [self] in
            if phone.hasPreciseLocation {
                begin(call)
            } else if phone.hasApproximateLocation && !approximateBefore {
                phone.askLocation { [self] in
                    phone.hasPreciseLocation ? begin(call) : refuse(call, TrackingService.errorLocationPermission)
                }
            } else {
                refuse(call, TrackingService.errorLocationPermission)
            }
        }
    }

    private func begin(_ call: Call) {
        guard running === call else { return }
        phone.start(call.request)
        finish(call, nil)
    }

    private func refuse(_ call: Call, _ error: String) {
        guard running === call else { return }
        phone.recordRefusal(call.request.missionID, error: error)
        finish(call, error)
    }

    private func finish(_ call: Call, _ error: String?) {
        // Abandoned while the person was answering: the page that asked is gone.
        guard running === call else { return }
        running = nil
        call.answer(error)
        runNext()
    }
}

/// The phone as the start flow sees it: Core Location's dialogs and the disclosure, shown over [presenter].
@MainActor
final class LocationPhone: NSObject, TrackingPhone, CLLocationManagerDelegate {
    let service: TrackingService
    weak var presenter: UIViewController?
    private let manager = CLLocationManager()
    private var pending: (() -> Void)?

    init(service: TrackingService, presenter: UIViewController) {
        self.service = service
        self.presenter = presenter
        super.init()
        manager.delegate = self
    }

    func disclose(_ then: @escaping (Bool) -> Void) {
        if service.disclosure.accepted { return then(true) }
        guard var top = presenter else { return then(false) }
        while let shown = top.presentedViewController { top = shown }
        let alert = UIAlertController(
            title: ShellStrings.text("tracking_disclosure_title", bundle: .module),
            message: String(format: ShellStrings.text("tracking_disclosure_text", bundle: .module), ShellStrings.appName()),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: ShellStrings.text("tracking_disclosure_decline", bundle: .module), style: .cancel) { _ in then(false) })
        alert.addAction(UIAlertAction(title: ShellStrings.text("tracking_disclosure_accept", bundle: .module), style: .default) { [service] _ in
            service.disclosure.accept()
            then(true)
        })
        alert.preferredAction = alert.actions.last
        top.present(alert, animated: true)
    }

    func locationOn(_ then: @escaping (Bool) -> Void) {
        Task {
            then(await Task.detached { CLLocationManager.locationServicesEnabled() }.value)
        }
    }

    var hasPreciseLocation: Bool { TrackingService.precise(manager) }

    var hasApproximateLocation: Bool {
        let status = manager.authorizationStatus
        return (status == .authorizedWhenInUse || status == .authorizedAlways) && manager.accuracyAuthorization == .reducedAccuracy
    }

    func askLocation(_ then: @escaping () -> Void) {
        if manager.authorizationStatus == .notDetermined {
            pending = then
            manager.requestWhenInUseAuthorization()
        } else if hasApproximateLocation {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: TrackingService.precisePurposeKey) { _ in
                Task { @MainActor in then() }
            }
        } else {
            // Refused before: the system shows no dialog again, the person changes it in Settings.
            then()
        }
    }

    func start(_ request: TrackingRequest) { service.start(request) }

    func recordRefusal(_ missionID: String, error: String) { service.store.recordRefusal(missionID, error: error) }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined, let then = self.pending else { return }
            self.pending = nil
            then()
        }
    }
}
