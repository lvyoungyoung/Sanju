import Foundation

struct SupabaseEmailSignInRequest: Encodable {
    let email: String
    let password: String
}

struct SupabaseEmailSignUpRequest: Encodable {
    let email: String
    let password: String
    let data: SupabaseEmailSignUpUserMetadata?
}

struct SupabaseEmailSignUpUserMetadata: Encodable {
    let nickname: String
}

struct SupabasePasswordResetRequest: Encodable {
    let email: String
}

struct SupabaseVerifyRecoveryOTPRequest: Encodable {
    let email: String
    let token: String
    let type: String
}

struct SupabasePasswordUpdateRequest: Encodable {
    let password: String
}

struct SupabaseRefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct SupabaseAnonymousSignInRequest: Encodable {
    let data: [String: String]

    init(data: [String: String] = [:]) {
        self.data = data
    }
}

struct SupabaseAuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SupabaseAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    var session: SupabaseSession {
        SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userID: user.id,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            isAnonymous: user.isAnonymous ?? false
        )
    }
}

struct SupabaseAuthUser: Decodable {
    let id: String
    let isAnonymous: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case isAnonymous = "is_anonymous"
    }
}

struct SupabaseOptionalAuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let user: SupabaseAuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    var session: SupabaseSession? {
        guard let accessToken,
              let refreshToken,
              let expiresIn,
              let user else {
            return nil
        }

        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userID: user.id,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            isAnonymous: user.isAnonymous ?? false
        )
    }
}

struct SupabaseCurrentAuthUserResponse: Decodable {
    let id: String
    let email: String?
    let userMetadata: SupabaseCurrentAuthUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
}

struct SupabaseCurrentAuthUserMetadata: Decodable {
    let fullName: String?
    let name: String?
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case name
        case nickname
    }
}

struct SupabaseProfileUpsertPayload: Encodable {
    let id: String
    let appleUserID: String
    let nickname: String
    let email: String?
    let englishLevel: String
    let languageStyle: String
    let initialAvailableGenerations: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case appleUserID = "apple_user_id"
        case nickname
        case email
        case englishLevel = "english_level"
        case languageStyle = "language_style"
        case initialAvailableGenerations = "available_generations"
    }
}

struct SupabaseProfilePatchPayload: Encodable {
    let nickname: String?
    let englishLevel: String?
    let languageStyle: String?

    enum CodingKeys: String, CodingKey {
        case nickname
        case englishLevel = "english_level"
        case languageStyle = "language_style"
    }
}

struct SupabaseConfirmPurchaseRequest: Encodable {
    let transactionID: String
    let productID: String
}

struct SupabaseConfirmPurchaseResponse: Decodable {
    let success: Bool
    let alreadyProcessed: Bool
    let remainingCredits: Int
}

struct SupabaseGenerateMemoryRequest: Encodable {
    let imageBase64: String
    let englishLevel: String
    let languageStyle: String
    let guestJobID: String?

    enum CodingKeys: String, CodingKey {
        case imageBase64
        case englishLevel
        case languageStyle
        case guestJobID
    }
}

struct SupabaseGenerateMemoryResponse: Decodable {
    let memory: SupabaseGeneratedMemory
    let remainingCredits: Int
    let guestJobID: String?

    enum CodingKeys: String, CodingKey {
        case memory
        case remainingCredits
        case guestJobID
    }
}

struct SupabaseRecoverGuestGenerationResponse: Decodable {
    let recovered: Bool
    let guestJobID: String?
    let memory: SupabaseGeneratedMemory?
    let remainingCredits: Int?

    enum CodingKeys: String, CodingKey {
        case recovered
        case guestJobID
        case memory
        case remainingCredits
    }
}

struct SupabaseRecoverGuestGenerationRequest: Encodable {
    let guestJobID: String

    enum CodingKeys: String, CodingKey {
        case guestJobID
    }
}

struct SupabaseMigrateGuestCreditsRequest: Encodable {
    let guestRefreshToken: String
    let guestUserID: String

    enum CodingKeys: String, CodingKey {
        case guestRefreshToken
        case guestUserID
    }
}

struct SupabaseSentenceFavoritePatchPayload: Encodable {
    let isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case isFavorite = "is_favorite"
    }
}

struct SupabaseSentenceStudyQueueRequest: Encodable {
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case limit = "p_limit"
    }
}

struct SupabaseSentenceStudyResultRequest: Encodable {
    let sentenceID: String
    let wasCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case sentenceID = "p_sentence_id"
        case wasCorrect = "p_was_correct"
    }
}

struct SupabaseLocalSentenceStudyProgressMergeRequest: Encodable {
    let items: [SupabaseLocalSentenceStudyProgressMergeItem]

    enum CodingKeys: String, CodingKey {
        case items = "p_items"
    }
}

struct SupabaseLocalSentenceStudyProgressMergeItem: Encodable {
    let sentenceID: String
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: String?
    let lastStudiedAt: Date?
    let lastStudiedOn: String?
    let nextReviewOn: String

    enum CodingKeys: String, CodingKey {
        case sentenceID = "sentence_id"
        case learningStep = "learning_step"
        case masteredReviewCount = "mastered_review_count"
        case correctCount = "correct_count"
        case wrongCount = "wrong_count"
        case lastResult = "last_result"
        case lastStudiedAt = "last_studied_at"
        case lastStudiedOn = "last_studied_on"
        case nextReviewOn = "next_review_on"
    }
}

struct SupabaseStorageRemoveRequest: Encodable {
    let prefixes: [String]
}

struct SupabaseMemoryInsertPayload: Encodable {
    let id: String
    let userID: String
    let imagePath: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case imagePath = "image_url"
        case createdAt = "created_at"
    }
}

struct SupabaseMemorySentenceInsertPayload: Encodable {
    let id: String
    let memoryID: String
    let sortOrder: Int
    let english: String
    let chinese: String
    let isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case memoryID = "memory_id"
        case sortOrder = "sort_order"
        case english
        case chinese
        case isFavorite = "is_favorite"
    }
}

struct SupabaseAPIError: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey {
        case message
        case error
        case msg
        case errorDescription = "error_description"
        case code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let preferredMessage = [
            try container.decodeIfPresent(String.self, forKey: .message),
            try container.decodeIfPresent(String.self, forKey: .errorDescription),
            try container.decodeIfPresent(String.self, forKey: .error),
            try container.decodeIfPresent(String.self, forKey: .msg),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        let code = try container.decodeIfPresent(String.self, forKey: .code)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let preferredMessage {
            if let code, !code.isEmpty, !preferredMessage.localizedCaseInsensitiveContains(code) {
                message = "\(preferredMessage) [code=\(code)]"
            } else {
                message = preferredMessage
            }
            return
        }

        if let code, !code.isEmpty {
            message = code
            return
        }

        message = "Unknown API error"
    }
}
