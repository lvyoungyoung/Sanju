import Foundation

nonisolated enum CloudSpeechError: LocalizedError {
    case notConfigured
    case noSession
    case offline
    case invalidResponse
    case http(status: Int, code: String, providerStatus: Int?)
    case stream(code: String)
    case invalidAudio
    case descriptorMismatch
    case noMatchingSystemVoice

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Speech client is missing API configuration"
        case .noSession: return "No active session for cloud speech"
        case .offline: return "Device is offline"
        case .invalidResponse: return "Speech endpoint returned a non-HTTP response"
        case let .http(status, code, providerStatus):
            return "Speech HTTP \(status); code=\(code)" + (providerStatus.map { "; MiMo HTTP \($0)" } ?? "")
        case let .stream(code): return "Speech stream failed; code=\(code)"
        case .invalidAudio: return "Speech stream is malformed, incomplete or empty"
        case .descriptorMismatch: return "Speech descriptor does not match the request"
        case .noMatchingSystemVoice: return "No system voice is available for this language"
        }
    }
}

nonisolated enum SpeechResponseDiagnostics {
    static func error(status: Int, body: Data) -> CloudSpeechError {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = safeCode(json?["code"] as? String ?? json?["error"] as? String)
        return .http(status: status, code: code, providerStatus: json?["providerStatus"] as? Int)
    }

    // Log only bounded identifiers, never arbitrary response text, tokens or audio.
    static func safeCode(_ code: String?) -> String {
        guard let code, !code.isEmpty, code.count <= 80,
              code.range(of: "^[A-Za-z0-9_:-]+$", options: .regularExpression) != nil else { return "unknown" }
        return code
    }
}

nonisolated struct SpeechAudioStream {
    static let sampleRate = 24_000
    static let maximumBytes = sampleRate * 2 * 60
    private(set) var data = Data()
    private(set) var isComplete = false
    private let expectedDescriptor: SpeechDescriptor?
    private var receivedDescriptor = false

    init(expectedDescriptor: SpeechDescriptor? = nil) { self.expectedDescriptor = expectedDescriptor }

    mutating func consume(_ line: String) throws -> Data? {
        struct Event: Decodable {
            let type: String
            let data: String?
            let code: String?
            let descriptor: SpeechDescriptor?
        }
        guard !isComplete, line.utf8.count <= 512_000 else { throw CloudSpeechError.invalidAudio }
        let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
        switch event.type {
        case "descriptor":
            guard let expectedDescriptor, !receivedDescriptor, data.isEmpty,
                  event.descriptor == expectedDescriptor, expectedDescriptor.supportsPCMPlayback,
                  expectedDescriptor.isKnownProfile else {
                throw CloudSpeechError.descriptorMismatch
            }
            receivedDescriptor = true
            return nil
        case "audio":
            guard expectedDescriptor == nil || receivedDescriptor else { throw CloudSpeechError.descriptorMismatch }
            guard let encoded = event.data, let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty, data.count + chunk.count <= Self.maximumBytes else {
                throw CloudSpeechError.invalidAudio
            }
            data.append(chunk)
            return chunk
        case "done":
            guard expectedDescriptor == nil || receivedDescriptor else { throw CloudSpeechError.descriptorMismatch }
            guard !data.isEmpty, data.count.isMultiple(of: 2) else { throw CloudSpeechError.invalidAudio }
            isComplete = true
            return nil
        case "error":
            throw CloudSpeechError.stream(code: SpeechResponseDiagnostics.safeCode(event.code))
        default:
            throw CloudSpeechError.invalidAudio
        }
    }
}

@MainActor
struct CloudSpeechClient {
    private let session: URLSession
    private let baseURL = Bundle.main.supabaseURL.flatMap(URL.init(string:))
    private let publishableKey = Bundle.main.supabasePublishableKey

    var cacheNamespace: String { Bundle.main.supabasePersistenceNamespace ?? "unconfigured" }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func stream(text: String, voice: SpeechVoice = .mia, auth: SupabaseSession, onAudio: (Data) async throws -> Void) async throws -> Data {
        try await streamRequest(text: text, voice: voice, speech: nil, auth: auth, onAudio: onAudio)
    }

    func stream(request: SpeechRequest, auth: SupabaseSession, onAudio: (Data) async throws -> Void) async throws -> Data {
        guard request.isValid, request.owner == auth.userID else { throw CloudSpeechError.descriptorMismatch }
        return try await streamRequest(text: request.text, voice: request.descriptor.legacyVoice ?? .mia,
                                       speech: request, auth: auth, onAudio: onAudio)
    }

    private func streamRequest(text: String, voice: SpeechVoice, speech: SpeechRequest?, auth: SupabaseSession,
                               onAudio: (Data) async throws -> Void) async throws -> Data {
        guard let baseURL, let publishableKey else { throw CloudSpeechError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(speech == nil ? "functions/v1/synthesize-speech" : "functions/v1/synthesize-speech-v2"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        if let speech {
            struct Body: Encodable {
                let text: String
                let language: LearningLanguage
                let teachingLocale: TeachingLocale
                let descriptor: SpeechDescriptor
            }
            request.httpBody = try JSONEncoder().encode(Body(text: speech.text, language: speech.language,
                teachingLocale: speech.teachingLocale, descriptor: speech.descriptor))
        } else {
            request.httpBody = try JSONEncoder().encode(["text": text, "voice": voice.rawValue])
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudSpeechError.invalidResponse }
#if DEBUG
        print("[SpeechFlow] HTTP \(response.statusCode) <- \(request.url!.absoluteString); contentType=\(response.mimeType ?? "missing")")
#endif
        guard response.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count >= 4096 { break }
            }
            throw SpeechResponseDiagnostics.error(status: response.statusCode, body: body)
        }
        let returnedVoice = response.value(forHTTPHeaderField: "X-Speech-Voice")
        guard speech != nil || returnedVoice == voice.rawValue || (returnedVoice == nil && voice == .mia) else {
            throw CloudSpeechError.stream(code: "speech_voice_not_supported_by_server")
        }
        // Some gateways rewrite Content-Type. Validate the actual NDJSON events instead
        // of rejecting an otherwise valid audio stream based only on that header.
        var audio = SpeechAudioStream(expectedDescriptor: speech?.descriptor)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty { continue }
            if let chunk = try audio.consume(line) { try await onAudio(chunk) }
            if audio.isComplete { return audio.data }
        }
        throw CloudSpeechError.invalidAudio
    }
}
