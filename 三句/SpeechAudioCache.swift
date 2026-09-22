import CryptoKit
import Foundation

actor SpeechAudioCache {
    private let directory: URL
    private let maximumBytes = 64 * 1024 * 1024
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentenceSpeech", isDirectory: true)
    }

    nonisolated static func key(text: String, scope: String, voice: SpeechVoice = .mia) -> String {
        let input = "mimo-v2.5-tts:\(voice.rawValue):pcm24k:prompt1|\(scope)|\(text)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(_ key: String) -> Data? {
        let url = directory.appendingPathComponent(key).appendingPathExtension("pcm")
        guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = info.fileSize, size > 0, size <= SpeechAudioStream.maximumBytes,
              let date = info.contentModificationDate, Date().timeIntervalSince(date) < maximumAge,
              let data = try? Data(contentsOf: url), data.count.isMultiple(of: 2) else { return nil }
        return data
    }

    func save(_ data: Data, key: String) {
        guard !data.isEmpty, data.count <= SpeechAudioStream.maximumBytes, data.count.isMultiple(of: 2) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key).appendingPathExtension("pcm"),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try trim()
        } catch {
#if DEBUG
            print("[SpeechFlow] Audio cache write failed: \(error.localizedDescription)")
#endif
        }
    }

    private func trim() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "pcm" }
            .compactMap { url -> (URL, Int, Date)? in
                guard let info = try? url.resourceValues(forKeys: keys),
                      let size = info.fileSize, let date = info.contentModificationDate else { return nil }
                return (url, size, date)
            }.sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, date) in files where total > maximumBytes || Date().timeIntervalSince(date) > maximumAge {
            try FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
