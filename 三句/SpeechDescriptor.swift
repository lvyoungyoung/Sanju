import Foundation

nonisolated struct SpeechDescriptor: Codable, Equatable {
    let profileID: String
    let profileRevision: Int
    let language: LearningLanguage
    let teachingLocale: TeachingLocale
    let locale: String
    let provider: String
    let model: String
    let voice: String
    let audioFormat: String
    let sampleRate: Int
    let channels: Int
    let promptVersion: Int

    static func english(_ voice: SpeechVoice = .mia) -> Self {
        Self(profileID: "en-\(voice.rawValue.lowercased())", profileRevision: 1,
             language: LearningLanguage(rawValue: "en")!, teachingLocale: TeachingLocale(rawValue: "en-US")!,
             locale: "en-US", provider: "mimo", model: "mimo-v2.5-tts", voice: voice.rawValue,
             audioFormat: "pcm16le", sampleRate: 24_000, channels: 1, promptVersion: 2)
    }

    // Candidates are not validated voices. The server requires an explicit, revision-specific release gate.
    static func candidate(language: LearningLanguage, teachingLocale: TeachingLocale) -> Self {
        let locale = ["es": "es-419", "ja": "ja-JP", "fr": "fr-FR"][language.rawValue] ?? ""
        let voice = ["es": "Sonrisa", "ja": "Ono Anna", "fr": "Emilien"][language.rawValue] ?? ""
        let voiceID = voice.lowercased().replacingOccurrences(of: " ", with: "-")
        return Self(profileID: "\(language.rawValue)-qwen-\(voiceID)", profileRevision: 1,
                    language: language, teachingLocale: teachingLocale, locale: locale,
                    provider: "qwen", model: "qwen3-tts-flash", voice: voice,
                    audioFormat: "pcm16le", sampleRate: 24_000, channels: 1, promptVersion: 1)
    }

    var supportsPCMPlayback: Bool { audioFormat == "pcm16le" && sampleRate == 24_000 && channels == 1 }
    var legacyVoice: SpeechVoice? {
        guard let voice = SpeechVoice(rawValue: voice), self == .english(voice) else { return nil }
        return voice
    }

    var isKnownProfile: Bool {
        if language == .english { return legacyVoice != nil }
        return self == .candidate(language: language, teachingLocale: teachingLocale)
    }
}

nonisolated struct SpeechRequest: Equatable {
    let text: String
    let language: LearningLanguage
    let teachingLocale: TeachingLocale
    let owner: String
    let accountRevision: Int
    let descriptor: SpeechDescriptor

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.language == rhs.language &&
            lhs.teachingLocale == rhs.teachingLocale && lhs.owner == rhs.owner &&
            lhs.accountRevision == rhs.accountRevision && lhs.descriptor == rhs.descriptor
    }

    init(text: String, language: LearningLanguage, teachingLocale: TeachingLocale, owner: String,
         accountRevision: Int = 0, descriptor: SpeechDescriptor? = nil) {
        self.text = text
        self.language = language
        self.teachingLocale = teachingLocale
        self.owner = owner
        self.accountRevision = accountRevision
        self.descriptor = descriptor ?? (language.rawValue == "en" ? .english() : .candidate(language: language, teachingLocale: teachingLocale))
    }

    static func english(_ text: String, voice: SpeechVoice = .mia, owner: String, accountRevision: Int = 0) -> Self {
        let descriptor = SpeechDescriptor.english(voice)
        return Self(text: text.trimmingCharacters(in: .whitespacesAndNewlines), language: descriptor.language,
                    teachingLocale: descriptor.teachingLocale, owner: owner, accountRevision: accountRevision, descriptor: descriptor)
    }

    var isValid: Bool {
        let locales = ["en": "en-US", "es": "es-419", "ja": "ja-JP", "fr": "fr-FR"]
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 500 &&
            !owner.isEmpty && accountRevision >= 0 && locales[language.rawValue] == teachingLocale.rawValue &&
            descriptor.language == language && descriptor.teachingLocale == teachingLocale &&
            descriptor.locale.split(separator: "-").first.map(String.init) == language.rawValue &&
            descriptor.profileRevision > 0 && descriptor.supportsPCMPlayback && descriptor.isKnownProfile
    }

    var systemVoiceLocales: [String] {
        switch language.rawValue {
        case "en": return ["en-US"]
        case "es": return ["es-MX", "es-419", "es-US"]
        case "ja": return ["ja-JP"]
        case "fr": return ["fr-FR"]
        default: return []
        }
    }

    func preferredSystemLocale(available: [String]) -> String? {
        systemVoiceLocales.first { available.contains($0) }
    }
}
