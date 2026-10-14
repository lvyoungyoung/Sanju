import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyRPCIntegrationTests: XCTestCase {
    func testDurableDirectSessionAndLostResponseUseExactRPCIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions.json")
        let store = try StudySessionStore(fileURL: file)
        let sentenceID = UUID()
        let state = try store.prepare(ownerID: "test-owner", language: .english, mode: "due",
            directSentenceID: sentenceID, revision: UUID())
        let item = SentenceStudyQueueItem(sentenceID: sentenceID, memoryID: UUID(),
            english: "The coffee is warm.", chinese: "咖啡是热的。", imagePath: "", createdAt: .now,
            learningStep: 0, masteredReviewCount: 0, correctCount: 0, wrongCount: 0,
            lastResult: nil, nextReviewAt: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = try JSONSerialization.jsonObject(with: encoder.encode(MultilingualStudyQueueRecord(item: item)))
        let begin = try JSONSerialization.data(withJSONObject: ["session_id": state.id.uuidString,
            "remaining_new": 29, "items": [record]])
        let progress = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
            "sentence_id": sentenceID.uuidString, "learning_step": 1, "mastered_review_count": 0,
            "correct_count": 1, "wrong_count": 0, "last_result": "correct",
            "last_studied_at": "2026-10-14T10:00:00Z", "next_review_at": "2026-10-15T00:00:00Z"])
        StudyTestURLProtocol.configure([begin, nil, progress])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudyTestURLProtocol.self]
        let api = SupabaseService(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://study.invalid")!, publishableKey: "test")
        let session = SupabaseSession(accessToken: "test", refreshToken: "test", userID: "test-owner",
            expiresAt: .distantFuture, isAnonymous: false)
        let queue = try await api.beginMultilingualStudySession(session: session, state: state)
        try store.confirm(state, queue: queue)
        _ = try store.enqueue(state, sentenceID: sentenceID)
        do {
            try await store.replay(ownerID: session.userID, revision: UUID(), isCurrent: { true }) { state, id in
                try await api.recordMultilingualStudyEvent(session: session, state: state, sentenceID: id)
            }
            XCTFail("A lost response must remain pending")
        } catch is URLError {}
        let reopened = try StudySessionStore(fileURL: file)
        try await reopened.replay(ownerID: session.userID, revision: UUID(), isCurrent: { true }) { state, id in
            try await api.recordMultilingualStudyEvent(session: session, state: state, sentenceID: id)
        }
        XCTAssertEqual(reopened.receipts(ownerID: session.userID).first?.delivery, .acknowledged)
        let calls = StudyTestURLProtocol.recordedCalls()
        XCTAssertEqual(calls.map(\.path), ["/rest/v1/rpc/begin_direct_study_session_v2",
            "/rest/v1/rpc/record_study_event_v2", "/rest/v1/rpc/record_study_event_v2"])
        let beginBody = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[0].body) as? [String: Any])
        XCTAssertEqual(beginBody["p_sentence_id"] as? String, sentenceID.uuidString)
        XCTAssertEqual(beginBody["p_session_id"] as? String, state.id.uuidString)
        let firstEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[1].body) as? NSDictionary)
        let retryEvent = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[2].body) as? NSDictionary)
        XCTAssertEqual(firstEvent, retryEvent)
        XCTAssertEqual(firstEvent["p_time_zone"] as? String, state.timeZoneID)
    }
}

private nonisolated final class StudyTestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Call { let path: String; let body: Data }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [Data?] = []
    private nonisolated(unsafe) static var calls: [Call] = []

    static func configure(_ values: [Data?]) {
        lock.lock(); defer { lock.unlock() }
        replies = values; calls = []
    }
    static func recordedCalls() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.calls.append(Call(path: request.url!.path, body: body))
        let data = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
