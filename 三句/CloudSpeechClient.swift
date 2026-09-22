import Foundation

enum CloudSpeechError: Error {
    case unavailable
    case invalidAudio
}

nonisolated struct SpeechAudioStream {
    static let sampleRate = 24_000
    static let maximumBytes = sampleRate * 2 * 60
    private(set) var data = Data()
    private(set) var isComplete = false

    mutating func consume(_ line: String) throws -> Data? {
        struct Event: Decodable {
            let type: String
            let data: String?
        }
        guard !isComplete, line.utf8.count <= 512_000 else { throw CloudSpeechError.invalidAudio }
        let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
        switch event.type {
        case "audio":
            guard let encoded = event.data, let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty, data.count + chunk.count <= Self.maximumBytes else {
                throw CloudSpeechError.invalidAudio
            }
            data.append(chunk)
            return chunk
        case "done":
            guard !data.isEmpty, data.count.isMultiple(of: 2) else { throw CloudSpeechError.invalidAudio }
            isComplete = true
            return nil
        default:
            throw CloudSpeechError.invalidAudio
        }
    }
}

@MainActor
final class CloudSpeechClient {
    private let session: URLSession
    private let baseURL = Bundle.main.supabaseURL.flatMap(URL.init(string:))
    private let publishableKey = Bundle.main.supabasePublishableKey

    var cacheNamespace: String { baseURL?.absoluteString ?? "unconfigured" }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func stream(text: String, auth: SupabaseSession, onAudio: (Data) throws -> Void) async throws -> Data {
        guard let baseURL, let publishableKey else { throw CloudSpeechError.unavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent("functions/v1/synthesize-speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(["text": text])

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == "application/x-ndjson" else { throw CloudSpeechError.unavailable }
        var audio = SpeechAudioStream()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty { continue }
            if let chunk = try audio.consume(line) { try onAudio(chunk) }
            if audio.isComplete { return audio.data }
        }
        throw CloudSpeechError.invalidAudio
    }
}
