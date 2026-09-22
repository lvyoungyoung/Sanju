import Foundation

nonisolated enum SpeechVoice: String, CaseIterable, Identifiable, Codable {
    case mia = "Mia"
    case chloe = "Chloe"
    case milo = "Milo"
    case dean = "Dean"

    var id: String { rawValue }
    var isFemale: Bool { self == .mia || self == .chloe }
}

nonisolated enum SpeechPreferenceKey {
    static let voice = "sanju.speech.voice"
    static let legacySpeed = "sanju.speech.speed"
}

nonisolated struct SpeechPreferences {
    var voice: SpeechVoice = .mia

    init(defaults: UserDefaults) {
        voice = defaults.string(forKey: SpeechPreferenceKey.voice).flatMap(SpeechVoice.init(rawValue:)) ?? .mia
        defaults.removeObject(forKey: SpeechPreferenceKey.legacySpeed)
    }

    static let previewText = "Every photo tells a story. Let's learn something new today."
}
