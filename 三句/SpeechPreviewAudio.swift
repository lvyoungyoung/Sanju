import Foundation

nonisolated enum SpeechPreviewAudio {
    static func load(_ voice: SpeechVoice, bundle: Bundle = .main) throws -> Data {
        let name = "speech-preview-\(voice.rawValue.lowercased())"
        guard let url = bundle.url(forResource: name, withExtension: "pcm")
            ?? bundle.url(forResource: name, withExtension: "pcm", subdirectory: "SpeechPreviews") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count.isMultiple(of: 2),
              data.count <= SpeechAudioStream.maximumBytes else {
            throw CloudSpeechError.invalidAudio
        }
        return data
    }
}
