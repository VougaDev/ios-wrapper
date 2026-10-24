import CoreLocation
import VougaDevOfflineMap
import XCTest
@testable import VougaDevShell
@testable import VougaDevTracking

let missionID = "0b5f2a6e-7a8c-4c3e-9d1f-2b3c4d5e6f70"
let positionPath = "/api/v1/courier/missions/\(missionID)/position"
let paths = TrackingPaths(position: "/api/v1/courier/missions/{id}/position", target: "/api/v1/courier/tracking")

final class TrackingRequestTests: XCTestCase {

    func testParseTheContractsShape() {
        let parsed = TrackingRequest.parse(json(#"""
        {"missionId": "0B5F2A6E-7A8C-4C3E-9D1F-2B3C4D5E6F70", "url": "/api/v1/courier/missions/0b5f2a6e-7a8c-4c3e-9d1f-2b3c4d5e6f70/position",
         "intervalSeconds": 5, "target": {"lat": 0.39, "lng": 9.45}, "title": " On the way ", "text": null}
        """#), paths: paths)
        XCTAssertEqual(parsed, .accepted(TrackingRequest(missionID: missionID, path: paths.position(missionID)!, intervalSeconds: 15, target: LatLng(lat: 0.39, lng: 9.45),
                                                         title: "On the way", text: nil)))
    }

    func testRefusals() {
        XCTAssertEqual(TrackingRequest.parse(nil as JSONObject?, paths: paths), .refused("invalid_request"))
        XCTAssertEqual(TrackingRequest.parse(["missionId": "12"], paths: paths), .refused("invalid_mission_id"))
        XCTAssertEqual(TrackingRequest.parse(["missionId": missionID, "url": "https://evil.io/steal"], paths: paths), .refused("invalid_url"))
        XCTAssertEqual(TrackingRequest.parse(["missionId": missionID, "url": "/api/v1/courier/missions/\(missionID)/other"], paths: paths), .refused("invalid_url"))
        XCTAssertEqual(TrackingRequest.parse(json: "{", paths: paths), .refused("invalid_json"))
    }

    func testIntervalTargetAndWords() {
        XCTAssertEqual(TrackingRequest.clampInterval(nil), 60)
        XCTAssertEqual(TrackingRequest.clampInterval(.infinity), 60)
        XCTAssertEqual(TrackingRequest.clampInterval(1e300), 300)
        XCTAssertEqual(TrackingRequest.clampInterval(90.7), 90)
        let request = TrackingRequest.parse(["missionId": missionID, "intervalSeconds": true, "target": ["lat": 91, "lng": 0],
                                             "title": String(repeating: "x", count: 100)], paths: paths).request!
        XCTAssertEqual(request.intervalSeconds, 60, "true is not a number")
        XCTAssertNil(request.target, "a target out of range is dropped, not fatal")
        XCTAssertEqual(request.title?.count, 80)
        XCTAssertEqual(TrackingRequest.parse(json: request.json, paths: paths), .accepted(request), "what is kept reads back the same")
        XCTAssertEqual(request.path, positionPath)
    }

    func testTarget() {
        let current = TrackingRequest(missionID: missionID, path: paths.position(missionID)!, intervalSeconds: 60, target: nil, title: "t", text: "x")
        let other = "1b5f2a6e-7a8c-4c3e-9d1f-2b3c4d5e6f70"
        let body = json(#"{"mission": {"id": "\#(other)", "status": "underway", "url": "/api/v1/courier/missions/\#(other)"}, "interval_seconds": 30}"#)
        XCTAssertEqual(TrackingTarget.next(body, current: current, paths: paths),
                       TrackingRequest(missionID: other, path: paths.position(other)!, intervalSeconds: 30, target: nil, title: "t", text: "x"))
        XCTAssertNil(TrackingTarget.next(json(#"{"mission": {"id": "\#(missionID)"}}"#), current: current, paths: paths), "never the mission that ended")
        XCTAssertNil(TrackingTarget.next(json(#"{"mission": null}"#), current: current, paths: paths))
        XCTAssertEqual(TrackingTarget.atLaunch(json(#"{"mission": null}"#), active: missionID, paths: paths), .stop)
        XCTAssertEqual(TrackingTarget.atLaunch(body, active: other, paths: paths), .keep)
        guard case .start = TrackingTarget.atLaunch(body, active: nil, paths: paths) else { return XCTFail() }
    }

    func testPingOutcomes() {
        XCTAssertEqual(PingOutcome.classify(.ok([:])), .sent)
        XCTAssertEqual(PingOutcome.classify(.sessionLost), .stopSession)
        XCTAssertEqual(PingOutcome.classify(.refused(status: 404, code: "", detail: "x")), .stopMission)
        XCTAssertEqual(PingOutcome.classify(.refused(status: 400, code: "not_on_the_road", detail: "")), .stopMission)
        XCTAssertEqual(PingOutcome.classify(.refused(status: 400, code: "position_missing", detail: "")), .retry)
        XCTAssertEqual(PingOutcome.classify(.failed(status: 404)), .stopMission)
        XCTAssertEqual(PingOutcome.classify(.failed(status: 502)), .retry)
        XCTAssertEqual(PingOutcome.classify(.offline), .retry)
        XCTAssertEqual(PingOutcome.retryError(.failed(status: 502)), "http_502")
        XCTAssertEqual(PingOutcome.retryError(.offline), "network_error")
    }

    func testFixPolicyAndDistance() {
        let now = Date()
        XCTAssertTrue(FixPolicy.isFresh(now.addingTimeInterval(-119), now: now))
        XCTAssertFalse(FixPolicy.isFresh(now.addingTimeInterval(-121), now: now))
        XCTAssertTrue(FixPolicy.isBetter(candidateAt: now, candidateAccuracy: nil, currentAt: nil, currentAccuracy: nil))
        XCTAssertFalse(FixPolicy.isBetter(candidateAt: now, candidateAccuracy: 5, currentAt: now, currentAccuracy: 5))
        XCTAssertFalse(FixPolicy.isBetter(candidateAt: now, candidateAccuracy: 500, currentAt: now.addingTimeInterval(-5), currentAccuracy: 8),
                       "a vague fix seconds later keeps the GPS fix")
        XCTAssertTrue(FixPolicy.isBetter(candidateAt: now, candidateAccuracy: 500, currentAt: now.addingTimeInterval(-60), currentAccuracy: 8))
        // Libreville to Owendo, about 11.8 km
        let d = FixPolicy.distance(LatLng(lat: 0.3901, lng: 9.4544), LatLng(lat: 0.2939, lng: 9.4983))
        XCTAssertEqual(d, 11_760, accuracy: 300)
        XCTAssertEqual(FixPolicy.distance(LatLng(lat: 0, lng: 0), LatLng(lat: 0, lng: 180)), .pi * 6_371_008.8, accuracy: 1)
    }
}

@MainActor
final class TrackingStoreAndServiceTests: XCTestCase {

    func testStateKeepsWhyTrackingStopped() {
        let store = TrackingStore(defaults: freshDefaults(), paths: paths)
        XCTAssertEqual(NativeBridge.text(store.state(running: nil)), #"{"active":false,"lastError":null,"lastSentAt":null,"missionId":null}"#)
        let request = TrackingRequest(missionID: missionID, path: paths.position(missionID)!, intervalSeconds: 60, target: nil, title: nil, text: nil)
        store.save(request, startedAt: Date())
        store.recordSent(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(NativeBridge.text(store.state(running: missionID)),
                       #"{"active":true,"lastError":null,"lastSentAt":1700000000000,"missionId":"\#(missionID)"}"#)
        store.recordError("mission_ended")
        store.clearRequest()
        XCTAssertNil(store.load())
        XCTAssertEqual(store.state(running: nil)["missionId"] as? String, missionID)
        XCTAssertEqual(store.state(running: nil)["lastError"] as? String, "mission_ended")
        store.forget()
        XCTAssertTrue(store.state(running: nil)["missionId"] is NSNull)
    }

    private func makeService(_ answer: @escaping (URLRequest) -> (Int, [String: String], String)) -> (TrackingService, FakeTransport) {
        let defaults = freshDefaults()
        let transport = FakeTransport(answer)
        let caller = AppCaller(origin: origin, cookies: { "csrftoken=t; sessionid=s" }, userAgent: { "UA" }, acceptLanguage: { "en" },
                               renew: { _ in .signIn }, transport: transport)
        let disclosure = TrackingDisclosure(defaults: defaults)
        disclosure.accept()
        let service = TrackingService(store: TrackingStore(defaults: defaults, paths: paths), disclosure: disclosure, caller: { caller })
        service.locationAllowed = { true }
        service.autoTicks = false
        return (service, transport)
    }

    private let request = TrackingRequest(missionID: missionID, path: paths.position(missionID)!, intervalSeconds: 300, target: LatLng(lat: 0.39, lng: 9.45), title: "t", text: nil)

    func testATickPostsTheFreshFixWithItsDistance() async throws {
        let (service, transport) = makeService { _ in (200, [:], #"{"tracked_at": "now", "interval_seconds": 60}"#) }
        service.start(request)
        let stillRunning = await service.tick(request)
        XCTAssertTrue(stillRunning)
        XCTAssertEqual(service.state()["lastError"] as? String, "no_recent_fix")
        service.receive(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0.391, longitude: 9.45), altitude: 0,
                                   horizontalAccuracy: 6, verticalAccuracy: -1, timestamp: Date()))
        let sent = await service.tick(request)
        XCTAssertTrue(sent)
        let post = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(post.url?.absoluteString, "https://app.example.org" + positionPath)
        let body = json(String(decoding: post.httpBody!, as: UTF8.self))
        XCTAssertEqual(body["accuracy_m"] as? Double, 6)
        XCTAssertEqual(body["distance_m"] as? Double, 111)
        XCTAssertNotNil(body["fix_at_ms"] as? Int64)
        XCTAssertTrue(service.state()["lastError"] is NSNull)
        XCTAssertEqual(service.state()["active"] as? Bool, true)
        service.stop()
        XCTAssertEqual(service.state()["active"] as? Bool, false)
    }

    func testAnEndedMissionHandsOverOnceOrStops() async {
        let next = "1b5f2a6e-7a8c-4c3e-9d1f-2b3c4d5e6f70"
        let (service, transport) = makeService { request in
            request.url!.path.hasSuffix("/tracking")
                ? (200, [:], #"{"mission": {"id": "\#(next)"}, "interval_seconds": 60}"#)
                : (400, [:], #"{"code": "not_on_the_road", "detail": "Over."}"#)
        }
        service.start(request)
        service.receive(CLLocation(latitude: 0.39, longitude: 9.45))
        let handedOver = await service.tick(request)
        XCTAssertTrue(handedOver)
        XCTAssertEqual(service.runningMissionID, next)
        XCTAssertEqual(transport.sent.count, 2)

        let second = service.request!
        transport.answer = { request in
            request.url!.path.hasSuffix("/tracking") ? (200, [:], #"{"mission": null}"#) : (404, [:], "")
        }
        let lastTick = await service.tick(second)
        XCTAssertFalse(lastTick)
        XCTAssertNil(service.runningMissionID)
        XCTAssertEqual(service.state()["lastError"] as? String, "mission_ended")
    }

    func testALostSessionStopsTracking() async {
        let (service, _) = makeService { _ in (401, [:], "") }
        service.start(request)
        service.receive(CLLocation(latitude: 0.39, longitude: 9.45))
        let running = await service.tick(request)
        XCTAssertFalse(running)
        XCTAssertEqual(service.state()["lastError"] as? String, "session_lost")
    }

    func testNothingStartsBeforeTheDisclosureIsAccepted() {
        let defaults = freshDefaults()
        let service = TrackingService(store: TrackingStore(defaults: defaults, paths: paths), disclosure: TrackingDisclosure(defaults: defaults),
                                      caller: { fatalError("no call") })
        service.locationAllowed = { true }
        service.start(request)
        XCTAssertNil(service.runningMissionID)
    }
}

@MainActor
final class FakePhone: TrackingPhone {
    var agrees = true
    var on = true
    var precise = false
    var approximate = false
    /// What each dialog grants: (precise, approximate).
    var grants: [(Bool, Bool)] = []
    private(set) var asked = 0
    private(set) var started: [String] = []
    private(set) var refusals: [String] = []
    var hold = false
    var held: [() -> Void] = []

    func disclose(_ then: @escaping (Bool) -> Void) {
        if hold { held.append { then(self.agrees) } } else { then(agrees) }
    }
    func locationOn(_ then: @escaping (Bool) -> Void) { then(on) }
    var hasPreciseLocation: Bool { precise }
    var hasApproximateLocation: Bool { approximate }
    func askLocation(_ then: @escaping () -> Void) {
        asked += 1
        if !grants.isEmpty { (precise, approximate) = grants.removeFirst() }
        then()
    }
    func start(_ request: TrackingRequest) { started.append(request.missionID) }
    func recordRefusal(_ missionID: String, error: String) { refusals.append(error) }
}

@MainActor
final class TrackingStartFlowTests: XCTestCase {

    let request = TrackingRequest(missionID: missionID, path: paths.position(missionID)!, intervalSeconds: 60, target: nil, title: nil, text: nil)

    private func run(_ phone: FakePhone) -> String?? {
        var answer: String??
        TrackingStartFlow(phone: phone).submit(request) { answer = .some($0) }
        return answer
    }

    func testPreciseHeldStartsAtOnce() {
        let phone = FakePhone()
        phone.precise = true
        XCTAssertEqual(run(phone), .some(nil))
        XCTAssertEqual(phone.started, [missionID])
        XCTAssertEqual(phone.asked, 0)
    }

    func testDeclinedDisclosureStartsNothing() {
        let phone = FakePhone()
        phone.agrees = false
        phone.precise = true
        XCTAssertEqual(run(phone), .some("tracking_declined"))
        XCTAssertEqual(phone.started, [])
        XCTAssertEqual(phone.refusals, ["tracking_declined"])
    }

    func testLocationServicesOff() {
        let phone = FakePhone()
        phone.on = false
        XCTAssertEqual(run(phone), .some("location_disabled"))
        XCTAssertEqual(phone.asked, 0)
    }

    func testApproximateIsAskedForPreciseOnceMore() {
        let phone = FakePhone()
        phone.grants = [(false, true), (true, false)]
        XCTAssertEqual(run(phone), .some(nil))
        XCTAssertEqual(phone.asked, 2)

        let stubborn = FakePhone()
        stubborn.grants = [(false, true), (false, true)]
        XCTAssertEqual(run(stubborn), .some("location_permission_denied"))
        XCTAssertEqual(stubborn.asked, 2)

        let alreadyApproximate = FakePhone()
        alreadyApproximate.approximate = true
        alreadyApproximate.grants = [(false, true)]
        XCTAssertEqual(run(alreadyApproximate), .some("location_permission_denied"))
        XCTAssertEqual(alreadyApproximate.asked, 1, "that first dialog was the precise one")

        let refused = FakePhone()
        refused.grants = [(false, false)]
        XCTAssertEqual(run(refused), .some("location_permission_denied"))
    }

    func testCallsAreQueuedAndAbandonedOnSignOut() {
        let phone = FakePhone()
        phone.precise = true
        phone.hold = true
        let flow = TrackingStartFlow(phone: phone)
        var answers: [String?] = []
        flow.submit(request) { answers.append($0) }
        flow.submit(request) { answers.append($0) }
        XCTAssertEqual(phone.held.count, 1, "one dialog at a time")
        phone.held.removeFirst()()
        XCTAssertEqual(answers, [nil])
        XCTAssertEqual(phone.held.count, 1)
        flow.abandon()
        phone.held.removeFirst()()
        XCTAssertEqual(answers, [nil], "nobody is left to answer")
    }
}

final class LocalizationTests: XCTestCase {

    private func table(_ language: String, _ bundle: Bundle) throws -> [String: String] {
        let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language), language)
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
    }

    func testEveryTextInEnglishFrenchAndSpanish() throws {
        for bundle in [ShellResources.bundle, TrackingResources.bundle, OfflineMapResources.bundle] {
            let english = try table("en", bundle)
            XCTAssertFalse(english.isEmpty)
            for language in ["fr", "es"] {
                let other = try table(language, bundle)
                XCTAssertEqual(Set(other.keys), Set(english.keys), language)
                for (key, text) in english where text.contains("%@") {
                    XCTAssertTrue(other[key]?.contains("%@") == true, "\(language) \(key)")
                }
            }
        }
        XCTAssertNotEqual(try table("fr", ShellResources.bundle)["shell_signin_text"], try table("en", ShellResources.bundle)["shell_signin_text"])
    }

    /// App Review 2.3.10: no other platform named inside the app.
    func testNoOtherPlatformIsNamed() throws {
        for bundle in [ShellResources.bundle, TrackingResources.bundle, OfflineMapResources.bundle] {
            for language in ["en", "fr", "es"] {
                for text in try table(language, bundle).values {
                    XCTAssertNil(text.range(of: "android|google play|play store|\\.apk", options: [.regularExpression, .caseInsensitive]), text)
                }
            }
        }
    }
}
