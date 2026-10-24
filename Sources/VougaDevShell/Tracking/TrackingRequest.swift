import Foundation

/// The missions' addresses, exactly as the site writes them:
///
/// - `/courier/missions/`              the missions list;
/// - `/courier/missions/<uuid>/`       one mission;
/// - `/api/v1/courier/missions/<uuid>/position`   where its positions go;
/// - `/api/v1/courier/tracking`        which mission the position belongs to now.
public enum MissionRoute {
    public static let listPath = "/courier/missions/"
    public static let trackingPath = "/api/v1/courier/tracking"
    public static let refusedRoute = "route_refused"

    static let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    public static func isMissionID(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.range(of: "^\(uuid)$", options: .regularExpression) != nil
    }

    public static func positionPath(_ missionID: String) -> String? {
        isMissionID(missionID) ? "/api/v1/courier/missions/\(missionID)/position" : nil
    }

    /// The mission id a same-origin path names (`.some(nil)` for the list), or nil for any other path.
    public static func ofPath(_ path: String?) -> String?? {
        guard let path else { return nil }
        if path == listPath { return .some(nil) }
        let prefix = listPath
        guard path.hasPrefix(prefix), path.hasSuffix("/") else { return nil }
        let id = String(path.dropFirst(prefix.count).dropLast())
        return isMissionID(id) ? .some(id.lowercased()) : nil
    }

    /// `openMissions({url})`: no url is the list; else a same-origin PATH (never a URL with a host) that is a missions
    /// page. The page path to open, or nil (`route_refused`).
    public static func page(forBridgeURL url: String?) -> String? {
        guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return listPath }
        guard url.hasPrefix("/"), !url.hasPrefix("//") else { return nil }
        let path = String(url.prefix { $0 != "#" }.prefix { $0 != "?" })
        guard let id = ofPath(path) else { return nil }
        return id.map { listPath + $0 + "/" } ?? listPath
    }
}

/// A point on Earth, degrees.
public struct LatLng: Equatable, Sendable {
    public let lat: Double
    public let lng: Double
}

/// What the app is asked to track: by the server at launch or at a hand-over ([TrackingTarget]), or by a page through
/// `window.VougaDevNative.startTracking(object)`:
///
/// ```
/// {"missionId": "<uuid>", "url": "/api/v1/courier/missions/<uuid>/position", "intervalSeconds": 60,
///  "target": {"lat": 0.39, "lng": 9.45} | null, "title": "...", "text": "..."}
/// ```
///
/// The position always goes to the mission's own address, [path]; a page's `url` may be left out, and is refused when
/// it names any other address. [target] is the stop the courier heads for: without it `distance_m` is left out and the
/// server measures it. `title` and `text` are kept for the contract's shape (Android's notification shows them).
public struct TrackingRequest: Equatable, Sendable {
    public let missionID: String
    public let intervalSeconds: Int
    public let target: LatLng?
    public let title: String?
    public let text: String?

    public static let minIntervalSeconds = 15
    public static let maxIntervalSeconds = 300
    public static let defaultIntervalSeconds = 60
    public static let invalidJSON = "invalid_json"
    public static let invalidRequest = "invalid_request"
    public static let invalidMissionID = "invalid_mission_id"
    public static let invalidURL = "invalid_url"

    /// `/api/v1/courier/missions/<id>/position`; [missionID] was checked to be a UUID.
    public var path: String { MissionRoute.positionPath(missionID)! }

    public enum Parsed: Equatable {
        case accepted(TrackingRequest)
        case refused(String)
    }

    /// Missing or unreadable means the default; anything else is held to 15...300 seconds.
    public static func clampInterval(_ seconds: Double?) -> Int {
        guard let seconds, seconds.isFinite else { return defaultIntervalSeconds }
        return Int(min(max(seconds, Double(minIntervalSeconds)), Double(maxIntervalSeconds)))
    }

    /// The object a page passed to `startTracking(...)`; nil (a string, a number, nothing) is `invalid_request`.
    public static func parse(_ object: JSONObject?) -> Parsed {
        guard let object else { return .refused(invalidRequest) }
        guard let missionID = string(object["missionId"])?.lowercased(), MissionRoute.isMissionID(missionID) else {
            return .refused(invalidMissionID)
        }
        // The page cannot make the app carry the courier's session anywhere but this mission's address.
        if let url = string(object["url"]), url != MissionRoute.positionPath(missionID) { return .refused(invalidURL) }
        // A target the page could not describe is dropped, not fatal: the server measures the distance itself.
        let target = (object["target"] as? JSONObject).flatMap { point(number($0["lat"]), number($0["lng"])) }
        return .accepted(TrackingRequest(
            missionID: missionID,
            intervalSeconds: clampInterval(number(object["intervalSeconds"])),
            target: target,
            title: string(object["title"]).map { String($0.prefix(80)) },
            text: string(object["text"]).map { String($0.prefix(200)) }
        ))
    }

    /// A request kept by [json] (or any JSON text): `invalid_json` when unreadable.
    public static func parse(json: String?) -> Parsed {
        guard let data = json?.data(using: .utf8), !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return .refused(invalidJSON) }
        return parse(object)
    }

    /// The shape [parse] reads, so a kept request goes back through the same checks.
    public var json: String {
        var object: JSONObject = ["missionId": missionID, "url": path, "intervalSeconds": intervalSeconds]
        if let target { object["target"] = ["lat": target.lat, "lng": target.lng] }
        if let title { object["title"] = title }
        if let text { object["text"] = text }
        return NativeBridge.text(object)
    }

    /// Nil when either coordinate is missing, not finite or out of range.
    static func point(_ lat: Double?, _ lng: Double?) -> LatLng? {
        guard let lat, let lng, lat.isFinite, lng.isFinite, (-90...90).contains(lat), (-180...180).contains(lng) else { return nil }
        return LatLng(lat: lat, lng: lng)
    }

    /// A trimmed, non-empty string; a JSON null or another type is nil.
    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A JSON number; `true` is not one (JSONSerialization reads both as NSNumber).
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// `GET /api/v1/courier/tracking`: which mission, if any, this courier's position belongs to now.
///
/// ```
/// {"mission": {"id": "<uuid>", "status": "underway", "url": "/api/v1/courier/missions/<uuid>"} | null,
///  "interval_seconds": 60}
/// ```
///
/// Asked once per sign-in when a page of the site opens ([atLaunch]), and ONCE when a post answers that the tracked
/// mission is over ([next]), so a courier carrying several missions hands over from one to the next. Never on a timer.
public enum TrackingTarget {
    public static let path = MissionRoute.trackingPath

    public enum AtLaunch: Equatable {
        /// Nothing to track: tracking still running (or kept on the phone) stops.
        case stop
        /// The mission already tracked: carry on with it as it is.
        case keep
        case start(TrackingRequest)
    }

    /// [active]: the mission tracked, or the one kept on the phone; nil when none.
    public static func atLaunch(_ body: JSONObject?, active: String?) -> AtLaunch {
        guard let request = request(body, title: nil, text: nil) else { return .stop }
        return request.missionID == active ? .keep : .start(request)
    }

    /// The request to continue with, or nil to stop. The next mission has no target and keeps the current words. The
    /// mission that has just ended is never handed back: that would be a loop of refused posts.
    public static func next(_ body: JSONObject?, current: TrackingRequest) -> TrackingRequest? {
        guard let next = request(body, title: current.title, text: current.text), next.missionID != current.missionID else { return nil }
        return next
    }

    static func request(_ body: JSONObject?, title: String?, text: String?) -> TrackingRequest? {
        guard let mission = body?["mission"] as? JSONObject else { return nil }
        // The answer's `url` is the mission's detail, not where positions go: the request derives its own.
        let candidate: JSONObject = [
            "missionId": mission["id"] ?? NSNull(),
            "intervalSeconds": body?["interval_seconds"] ?? NSNull(),
            "title": title ?? NSNull(),
            "text": text ?? NSNull(),
        ]
        guard case let .accepted(request) = TrackingRequest.parse(candidate) else { return nil }
        return request
    }
}

/// What one position POST means for tracking.
public enum PingOutcome: Equatable {
    /// The server stored the position.
    case sent
    /// The mission is over, not started, or not this courier's: ask once which mission comes next.
    case stopMission
    /// The site's session is gone and the account service refused to renew it: the courier must sign in again.
    case stopSession
    /// Network, server or a one-off refusal: try again at the next tick, never in a burst.
    case retry

    static let gone: Set<Int> = [404, 410]
    static let over: Set<String> = ["not_on_the_road", "not_started", "not_your_mission"]

    /// The answer of `POST /api/v1/courier/missions/<id>/position`, after [AppCaller] tried to renew a lost session.
    public static func classify(_ answer: ApiOutcome) -> PingOutcome {
        switch answer {
        case .ok: return .sent
        case .sessionLost: return .stopSession
        case let .refused(status, code, _): return gone.contains(status) || over.contains(code) ? .stopMission : .retry
        case let .failed(status): return gone.contains(status) ? .stopMission : .retry
        case .offline: return .retry
        }
    }

    /// What `trackingState().lastError` says of a retried answer.
    public static func retryError(_ answer: ApiOutcome) -> String {
        switch answer {
        case let .refused(status, _, _), let .failed(status): return "http_\(status)"
        default: return TrackingService.errorNetwork
        }
    }
}

/// Which position fix is worth sending.
public enum FixPolicy {
    /// A fix older than this is not the courier's position any more, and is not sent.
    public static let maxAge: TimeInterval = 120
    /// Within this window a more accurate fix beats a newer, vaguer one.
    static let accuracyWindow: TimeInterval = 30

    /// A fix stamped a second ahead of the phone's clock still counts: Core Location stamps with the wall clock.
    public static func isFresh(_ fixAt: Date, now: Date) -> Bool { (-1...maxAge).contains(now.timeIntervalSince(fixAt)) }

    /// Whether [candidate] replaces [current]. A newer fix wins, except that a vague fix arriving seconds after a GPS fix
    /// must not throw away the GPS fix's accuracy. Accuracy is the radius in metres; nil means unknown.
    public static func isBetter(candidateAt: Date, candidateAccuracy: Double?, currentAt: Date?, currentAccuracy: Double?) -> Bool {
        guard let currentAt else { return true }
        if candidateAt <= currentAt { return false }
        if candidateAt.timeIntervalSince(currentAt) > accuracyWindow { return true }
        return (candidateAccuracy ?? .greatestFiniteMagnitude) <= (currentAccuracy ?? .greatestFiniteMagnitude)
    }

    /// Great-circle distance in metres, for the `distance_m` the phone reports to the stop it heads for.
    public static func distance(_ a: LatLng, _ b: LatLng) -> Double {
        let radius = 6_371_008.8  // mean Earth radius (IUGG)
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLat = lat2 - lat1, dLng = (b.lng - a.lng) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLng / 2), 2)
        // min(): rounding can push h a hair above 1 for antipodal points, and asin(>1) is NaN.
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
