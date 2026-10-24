import CoreLocation
import Foundation

/// SHARES THE STARTED COURIER'S POSITION WITH THE SITE WHILE A MISSION IS UNDER WAY, with the screen off too.
///
/// Started while the app is in front - which is what lets an app with "While Using the App" location keep receiving it
/// in the background, with the system's location indicator shown (`UIBackgroundModes = location`, App Review 2.5.4).
/// It never asks for "Always". Started by a page through `window.VougaDevNative.startTracking` (after
/// [TrackingStartFlow]), or when a page of the site opens and the server names a started mission ([follow]). It keeps
/// the best recent fix and, every `intervalSeconds`, posts it to `/api/v1/courier/missions/<id>/position` with the
/// distance to the stop the courier heads for, AS THE WEB VIEW'S SESSION through [AppCaller], which renews a lost
/// session itself.
///
/// When the server says the mission is over (404, or `not_on_the_road`), it asks ONCE which mission comes next
/// ([TrackingTarget]) and carries on with it, or stops. It stops when the account service refuses to renew the session, on [stop], at
/// sign-out, and six hours after the mission started. A network or server error is retried at the next tick and never
/// sooner. Updates are never paused by the system (`pausesLocationUpdatesAutomatically = false`): a courier waiting at a
/// pickup does not move, and that is exactly when the customer is waiting for the position.
@MainActor
public final class TrackingService: NSObject, CLLocationManagerDelegate {

    // What trackingState() reports as lastError, the same codes on every platform.
    public nonisolated static let errorLocationPermission = "location_permission_denied"
    public nonisolated static let errorLocationDisabled = "location_disabled"
    public nonisolated static let errorNoRecentFix = "no_recent_fix"
    public nonisolated static let errorNetwork = "network_error"
    public nonisolated static let errorMissionEnded = "mission_ended"
    public nonisolated static let errorSessionLost = "session_lost"
    public nonisolated static let errorTimeLimit = "time_limit"
    public nonisolated static let errorDeclined = "tracking_declined"

    /// The key of `NSLocationTemporaryUsageDescriptionDictionary` that explains why precise location is asked.
    public nonisolated static let precisePurposeKey = "Tracking"

    static let maxDuration: TimeInterval = 6 * 3600

    public let store: TrackingStore
    public let disclosure: TrackingDisclosure
    let caller: () -> AppCaller
    let manager = CLLocationManager()
    var clock: () -> Date = Date.init
    /// Precise location held: the service needs GPS-grade fixes. The tests replace it.
    lazy var locationAllowed: () -> Bool = { [manager] in Self.precise(manager) }
    /// False in the tests, which call [tick] themselves.
    var autoTicks = true

    private(set) var request: TrackingRequest?
    private var startedAt = Date()
    private var tickTask: Task<Void, Never>?
    private var latest: CLLocation?
    private var background: CLBackgroundActivitySession?

    public init(store: TrackingStore, disclosure: TrackingDisclosure, caller: @escaping () -> AppCaller) {
        self.store = store
        self.disclosure = disclosure
        self.caller = caller
        super.init()
        manager.delegate = self
    }

    /// The mission tracked right now; nil when tracking is off.
    public var runningMissionID: String? { request?.missionID }

    /// From the foreground only, after the start flow. Never before the courier agreed to the disclosure.
    public func start(_ next: TrackingRequest) {
        guard disclosure.accepted else { return }
        let saved = store.load()
        let sameMission = saved?.request.missionID == next.missionID
        let startedAt = sameMission ? saved!.startedAt : clock()
        if !sameMission { store.resetOutcome(next.missionID) }
        store.save(next, startedAt: startedAt)
        if let previous = request, previous.missionID == next.missionID, tickTask != nil {
            // The same mission is an update (its stop moved, its words changed): nothing restarts.
            request = next
            if previous.intervalSeconds != next.intervalSeconds { startTicking() }
            return
        }
        run(next, startedAt: startedAt)
    }

    public func stop() {
        store.clearRequest()
        tearDown()
    }

    /// Sign-out: tracking stops and what it kept of this person goes.
    public func forget() {
        stop()
        store.forget()
    }

    /// `trackingState()`.
    public func state() -> JSONObject { store.state(running: runningMissionID) }

    /// The server's `/courier/tracking` answer as a page of the site opens: start, keep or stop ([TrackingTarget.atLaunch]).
    public func follow(_ body: JSONObject) async {
        let active = runningMissionID ?? store.load()?.request.missionID
        switch TrackingTarget.atLaunch(body, active: active) {
        case .stop: if active != nil { stop() }
        case .keep: resumeIfPending()
        case let .start(next): if await canTrack() { start(next) }
        }
    }

    /// The app came back to the front with a mission kept on the phone and no tracking running.
    public func resumeIfPending() {
        guard runningMissionID == nil, disclosure.accepted, let saved = store.load() else { return }
        if clock().timeIntervalSince(saved.startedAt) > Self.maxDuration {
            store.recordError(Self.errorTimeLimit)
            store.clearRequest()
            return
        }
        Task {
            guard await canTrack(), runningMissionID == nil else { return }
            run(saved.request, startedAt: saved.startedAt)
        }
    }

    /// Precise location held and switched on: no dialog is shown for a start the person did not ask for.
    func canTrack() async -> Bool {
        guard locationAllowed() else { return false }
        return await Task.detached { CLLocationManager.locationServicesEnabled() }.value
    }

    private func run(_ next: TrackingRequest, startedAt: Date) {
        guard locationAllowed() else { return stopWith(Self.errorLocationPermission) }
        request = next
        self.startedAt = startedAt
        listen()
        startTicking()
    }

    private func listen() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        // Setting it without the background mode declared stops the app: an app without it tracks in the front only.
        if Self.declaresBackgroundLocation {
            if background == nil { background = CLBackgroundActivitySession() }
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        if let known = manager.location { receive(known) }
    }

    static var declaresBackgroundLocation: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    func receive(_ location: CLLocation) {
        let accuracy = { (fix: CLLocation) in fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : nil }
        if FixPolicy.isBetter(candidateAt: location.timestamp, candidateAccuracy: accuracy(location),
                              currentAt: latest?.timestamp, currentAccuracy: latest.flatMap(accuracy)) {
            latest = location
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        guard autoTicks else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let current = self.request else { return }
                if self.clock().timeIntervalSince(self.startedAt) > Self.maxDuration { return self.stopWith(Self.errorTimeLimit) }
                guard await self.tick(current), !Task.isCancelled else { return }
                // Read again: a hand-over may have brought another mission and its interval.
                guard let seconds = self.request?.intervalSeconds else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        }
    }

    /// One position, one POST. False when tracking has stopped.
    func tick(_ current: TrackingRequest) async -> Bool {
        guard let fix = latest, FixPolicy.isFresh(fix.timestamp, now: clock()) else {
            store.recordError(Self.errorNoRecentFix)
            return true
        }
        let answer = await caller().postJSON(current.path, Self.body(fix, target: current.target))
        // The request may have been replaced or stopped while the call was in flight.
        if request?.missionID != current.missionID { return request != nil }
        switch PingOutcome.classify(answer) {
        case .sent:
            store.recordSent(clock())
            return true
        case .retry:
            store.recordError(PingOutcome.retryError(answer))
            return true
        case .stopMission:
            return await handOver(current)
        case .stopSession:
            stopWith(Self.errorSessionLost)
            return false
        }
    }

    /// `{lat, lon, accuracy_m, fix_at_ms, distance_m}`; no target, no `distance_m`: the server measures it.
    static func body(_ fix: CLLocation, target: LatLng?) -> JSONObject {
        var body: JSONObject = [
            "lat": fix.coordinate.latitude,
            "lon": fix.coordinate.longitude,
            "fix_at_ms": Int64(fix.timestamp.timeIntervalSince1970 * 1000),
        ]
        if fix.horizontalAccuracy >= 0 { body["accuracy_m"] = fix.horizontalAccuracy }
        if let target {
            body["distance_m"] = FixPolicy.distance(LatLng(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude), target).rounded()
        }
        return body
    }

    /// The tracked mission is over. Ask the server ONCE which mission this courier's position belongs to now: carry on
    /// with it (no target, the same words), or stop. A failed question is a stop too - the next page asks again.
    private func handOver(_ ended: TrackingRequest) async -> Bool {
        let answer = await caller().get(TrackingTarget.path)
        if request?.missionID != ended.missionID { return request != nil }
        if answer.isSessionLost {
            stopWith(Self.errorSessionLost)
            return false
        }
        guard case let .ok(body) = answer, let next = TrackingTarget.next(body, current: ended) else {
            stopWith(Self.errorMissionEnded)
            return false
        }
        // A hand-over is not a new start by the courier: the six-hour cap keeps counting from the mission they started.
        store.resetOutcome(next.missionID)
        store.save(next, startedAt: startedAt)
        request = next
        return true
    }

    private func stopWith(_ error: String) {
        store.recordError(error)
        stop()
    }

    private func tearDown() {
        tickTask?.cancel()
        tickTask = nil
        manager.stopUpdatingLocation()
        if Self.declaresBackgroundLocation { manager.allowsBackgroundLocationUpdates = false }
        background?.invalidate()
        background = nil
        request = nil
        latest = nil
    }

    static func precise(_ manager: CLLocationManager) -> Bool {
        let status = manager.authorizationStatus
        return (status == .authorizedWhenInUse || status == .authorizedAlways) && manager.accuracyAuthorization == .fullAccuracy
    }

    // MARK: - CLLocationManagerDelegate (called on the main thread, where the manager was made)

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { locations.forEach { self.receive($0) } }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if self.request != nil && !self.locationAllowed() { self.stopWith(Self.errorLocationPermission) }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
