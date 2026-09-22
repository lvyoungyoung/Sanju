import Foundation

nonisolated enum SpeechVoice: String, CaseIterable, Identifiable, Codable {
    case mia = "Mia"
    case chloe = "Chloe"
    case milo = "Milo"
    case dean = "Dean"

    var id: String { rawValue }
    var isFemale: Bool { self == .mia || self == .chloe }
}

nonisolated enum SpeechSpeed: String, CaseIterable, Identifiable, Codable {
    case slower
    case normal

    var id: String { rawValue }
    var playbackRate: Float { self == .slower ? 0.85 : 1 }

    @MainActor var displayTitle: String {
        self == .slower ? L10n.string("speech.speed.slower", "稍慢") : L10n.string("speech.speed.normal", "正常")
    }
}

nonisolated enum SpeechPreferenceKey {
    static let voice = "sanju.speech.voice"
    static let speed = "sanju.speech.speed"
}

nonisolated struct SpeechPreferences {
    var voice: SpeechVoice = .mia
    var speed: SpeechSpeed = .normal

    init(defaults: UserDefaults) {
        voice = defaults.string(forKey: SpeechPreferenceKey.voice).flatMap(SpeechVoice.init(rawValue:)) ?? .mia
        speed = defaults.string(forKey: SpeechPreferenceKey.speed).flatMap(SpeechSpeed.init(rawValue:)) ?? .normal
    }

    static let previewText = "Every photo tells a story. Let's learn something new today."
}
