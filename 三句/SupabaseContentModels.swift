import Foundation

/// The versioned wire contract is strict. A bad row fails the entire page instead of disappearing.
struct SupabaseContentMemory: Codable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let imagePath: String
    let tags: [String]
    let context: MemoryContentContext
    let sentences: [SupabaseContentSentence]

    func validate() throws {
        guard schemaVersion == 2 else { throw LanguageContractError.unsupportedVersion }
        try context.validate()
        guard [3, 6, 12].contains(sentences.count), Set(sentences.map(\.id)).count == sentences.count else {
            throw SupabaseServiceError.invalidResponse
        }
        for sentence in sentences { try sentence.validate(context: context) }
        guard sentences.map(\.sentence).isCompleteSentenceCollection else {
            throw SupabaseServiceError.invalidResponse
        }
    }

    func memory(imageData: Data, isAnonymous: Bool) throws -> MemoryEntry {
        try validate()
        return MemoryEntry(id: id, createdAt: createdAt, imageData: imageData,
                           remoteImagePath: isAnonymous || imagePath.isEmpty ? nil : imagePath,
                           syncedToAccount: !isAnonymous, tags: tags,
                           sentences: sentences.map { $0.sentence }, context: context)
    }

    func record() throws -> SupabaseMemoryRecord {
        try validate()
        return SupabaseMemoryRecord(id: id.uuidString.lowercased(), imagePath: imagePath,
                                    createdAt: createdAt, tags: tags,
                                    sentences: sentences.enumerated().map { index, sentence in
            SupabaseMemorySentenceRecord(id: sentence.id.uuidString.lowercased(), sortOrder: index,
                english: sentence.targetText, chinese: sentence.translationText, learningTopicIDs: nil,
                presentationGroup: sentence.presentationGroup.rawValue,
                isFavorite: sentence.isFavorite, contentVersion: sentence.contentVersion,
                learningMaterial: sentence.learningMaterial, dialogue: sentence.dialogue)
        }, context: context)
    }

    init(memory: MemoryEntry, imagePath: String) {
        schemaVersion = 2
        id = memory.id
        createdAt = memory.createdAt
        self.imagePath = imagePath
        tags = memory.tags
        context = memory.context
        sentences = memory.sentences.map { SupabaseContentSentence($0) }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, createdAt, imagePath, tags, context, sentences }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        // Preserve subsecond identity; ISO8601's default encoder otherwise truncates guest timestamps.
        let micros = Int64((createdAt.timeIntervalSince1970 * 1_000_000).rounded())
        let seconds = micros / 1_000_000
        let formatter = ISO8601DateFormatter()
        let base = formatter.string(from: Date(timeIntervalSince1970: Double(seconds))).dropLast()
        try values.encode("\(base).\(String(format: "%06lld", micros % 1_000_000))Z", forKey: .createdAt)
        try values.encode(imagePath, forKey: .imagePath)
        try values.encode(tags, forKey: .tags)
        try values.encode(context, forKey: .context)
        try values.encode(sentences, forKey: .sentences)
    }
}

struct SupabaseContentSentence: Codable {
    let id: UUID
    let targetText: String
    let translationText: String
    let contentVersion: Int
    let presentationGroup: SentencePresentationGroup
    let isFavorite: Bool
    let learningMaterial: SentenceLearningMaterial?
    let dialogue: SentenceDialogue?

    init(_ sentence: SentenceRecord) {
        id = sentence.id
        targetText = sentence.targetText
        translationText = sentence.translationText
        contentVersion = sentence.contentVersion
        presentationGroup = sentence.presentationGroup
        isFavorite = sentence.isFavorite
        learningMaterial = sentence.learningMaterial
        dialogue = sentence.dialogue
    }

    func validate(context: MemoryContentContext) throws {
        guard contentVersion == 1 else { throw LanguageContractError.unsupportedVersion }
        if let dialogue, !dialogue.isValid { throw SupabaseServiceError.invalidResponse }
        guard !targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseServiceError.invalidResponse
        }
        if let learningMaterial {
            try learningMaterial.validate(targetText: targetText, language: context.targetLanguage)
        } else if context.targetLanguage == .japanese {
            throw SentenceLearningMaterial.ValidationError.materialRequired
        }
    }

    var sentence: SentenceRecord {
        SentenceRecord(id: id, targetText: targetText, translationText: translationText,
                       contentVersion: contentVersion, learningMaterial: learningMaterial,
                       presentationGroup: presentationGroup,
                       isFavorite: isFavorite, dialogue: dialogue)
    }
}

struct SupabaseContentCursor: Codable, Hashable {
    // Retain the server's exact timestamp precision for the keyset boundary.
    let createdAt: String
    let id: UUID
}

struct SupabaseContentPage: Decodable {
    let schemaVersion: Int
    let memories: [SupabaseContentMemory]
    let nextCursor: SupabaseContentCursor?
}

struct SupabaseContentGenerationResponse: Decodable {
    let status: String
    let recovered: Bool?
    let memory: SupabaseContentMemory?
    let remainingCredits: Int?
    let guestJobID: String?
    let clientRequestID: String?

    func result(imageData: Data, isAnonymous: Bool) throws -> SupabaseGenerateMemoryResult? {
        if status == "not_found" { return nil }
        guard status == "completed" || status == "acknowledged" else {
            throw SupabaseServiceError.apiError(status == "failed" ? "generation_failed" : "generation_pending")
        }
        guard let memory, let remainingCredits, remainingCredits >= 0, [3, 6, 12].contains(memory.sentences.count) else {
            throw SupabaseServiceError.invalidResponse
        }
        return SupabaseGenerateMemoryResult(memory: try memory.memory(imageData: imageData, isAnonymous: isAnonymous),
            remainingCredits: remainingCredits, guestJobID: guestJobID, clientRequestID: clientRequestID)
    }
}
