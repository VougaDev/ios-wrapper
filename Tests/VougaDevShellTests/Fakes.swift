import Foundation
@testable import VougaDevShell

/// Answers each request with [answer]; keeps what was sent.
final class FakeTransport: HttpTransport, @unchecked Sendable {
    var answer: (URLRequest) throws -> (Int, [String: String], String)
    private(set) var sent: [URLRequest] = []

    init(_ answer: @escaping (URLRequest) throws -> (Int, [String: String], String)) { self.answer = answer }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let (status, headers, body) = try answer(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

final class MemoryVault: SecretVault {
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { value }
    func write(_ value: String?) { self.value = value }
}

@MainActor
final class MemoryJar: CookieJar {
    var text: String?
    init(_ text: String? = nil) { self.text = text }
    func jar() async -> String? { text }
    func put(_ cookies: [HTTPCookie]) async {
        text = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func clear() async { text = nil }
}

final class FakeRefresher: Refresher {
    var answers: [TokenAnswer]
    private(set) var asked: [String] = []
    init(_ answers: [TokenAnswer]) { self.answers = answers }
    func refresh(_ refreshToken: String) async -> TokenAnswer {
        asked.append(refreshToken)
        return answers.isEmpty ? .unreachable : answers.removeFirst()
    }
}

let origin = AppOrigin("https://app.example.org")

func freshDefaults(_ name: String = #function) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "test.\(name)")!
    defaults.removePersistentDomain(forName: "test.\(name)")
    return defaults
}

func json(_ text: String) -> JSONObject {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSONObject ?? [:]
}
