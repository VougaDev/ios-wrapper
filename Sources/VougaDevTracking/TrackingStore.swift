import Foundation
import VougaDevShell

/// The mission being tracked, kept on the phone so an app the courier reopens after the system ended it carries on
/// with the same mission.
///
/// Two lifetimes live here. The REQUEST is the intent to track and is cleared the moment tracking stops. The OUTCOME
/// (`lastSentAt`, `lastError`) outlives it, so a page can still read why tracking stopped; it is reset only when another
/// mission starts.
public final class TrackingStore {
    let defaults: UserDefaults
    let paths: TrackingPaths

    public struct Active: Equatable {
        public let request: TrackingRequest
        public let startedAt: Date
    }

    public init(defaults: UserDefaults, paths: TrackingPaths) {
        self.defaults = defaults
        self.paths = paths
    }

    public func load() -> Active? {
        guard let json = defaults.string(forKey: Keys.request) else { return nil }
        guard case let .accepted(request) = TrackingRequest.parse(json: json, paths: paths) else {
            // Written by a build with another shape: not ours to resume.
            clearRequest()
            return nil
        }
        return Active(request: request, startedAt: Date(timeIntervalSince1970: defaults.double(forKey: Keys.startedAt)))
    }

    public func save(_ request: TrackingRequest, startedAt: Date) {
        defaults.set(request.json, forKey: Keys.request)
        defaults.set(startedAt.timeIntervalSince1970, forKey: Keys.startedAt)
        defaults.set(request.missionID, forKey: Keys.outcomeMission)
    }

    public func clearRequest() {
        defaults.removeObject(forKey: Keys.request)
        defaults.removeObject(forKey: Keys.startedAt)
    }

    /// A new mission: what happened to the previous one is not this one's history.
    public func resetOutcome(_ missionID: String) {
        defaults.set(missionID, forKey: Keys.outcomeMission)
        defaults.removeObject(forKey: Keys.lastSentAt)
        defaults.removeObject(forKey: Keys.lastError)
    }

    public func recordSent(_ at: Date) {
        defaults.set(Int64(at.timeIntervalSince1970 * 1000), forKey: Keys.lastSentAt)
        defaults.removeObject(forKey: Keys.lastError)
    }

    public func recordError(_ error: String) { defaults.set(error, forKey: Keys.lastError) }

    /// A refusal before tracking started (permission denied): it names the mission it was for.
    public func recordRefusal(_ missionID: String, error: String) {
        if defaults.string(forKey: Keys.outcomeMission) != missionID { resetOutcome(missionID) }
        recordError(error)
    }

    /// Everything, at sign-out: the next person's page reads nothing of this one's missions.
    public func forget() {
        [Keys.request, Keys.startedAt, Keys.outcomeMission, Keys.lastSentAt, Keys.lastError].forEach { defaults.removeObject(forKey: $0) }
    }

    /// `trackingState()`: `{active, missionId, lastSentAt, lastError}`. [running] is the mission tracked right now.
    public func state(running: String?) -> JSONObject {
        let kept = defaults.string(forKey: Keys.request).flatMap { TrackingRequest.parse(json: $0, paths: paths).request?.missionID }
        let missionID = running ?? kept ?? defaults.string(forKey: Keys.outcomeMission)
        let sentAt = defaults.object(forKey: Keys.lastSentAt) as? NSNumber
        return [
            "active": running != nil,
            "missionId": missionID ?? NSNull(),
            "lastSentAt": sentAt ?? NSNull(),
            "lastError": defaults.string(forKey: Keys.lastError) ?? NSNull(),
        ]
    }

    enum Keys {
        static let request = "tracking.request"
        static let startedAt = "tracking.started_at"
        static let outcomeMission = "tracking.outcome_mission"
        static let lastSentAt = "tracking.last_sent_at"
        static let lastError = "tracking.last_error"
    }
}

extension TrackingRequest.Parsed {
    var request: TrackingRequest? { if case let .accepted(request) = self { return request } else { return nil } }
}

/// THE DISCLOSURE BEFORE THE FIRST TRACKING (App Review 5.1.1 and 5.1.5; Google Play's prominent disclosure on the other
/// platform): the courier reads that the position is shared while a mission is under way, in the background too, and
/// agrees. Asked until agreed; until then no tracking starts from anywhere. A refusal never blocks the mission (5.1.2):
/// only the sharing is off, and it is asked again at the next start.
public final class TrackingDisclosure {
    let defaults: UserDefaults
    static let key = "tracking.disclosure_accepted"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var accepted: Bool { defaults.bool(forKey: Self.key) }

    public func accept() { defaults.set(true, forKey: Self.key) }
}
