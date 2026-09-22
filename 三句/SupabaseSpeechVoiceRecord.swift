import Foundation

struct SupabaseSpeechVoiceRecord: Decodable {
    let voice: SpeechVoice?

    enum CodingKeys: String, CodingKey {
        case voice = "speech_voice"
    }
}
