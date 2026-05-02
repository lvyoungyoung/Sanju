import Foundation

struct SupabaseSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userID: String
    let expiresAt: Date
    let isAnonymous: Bool
}

struct SupabaseProfileRecord: Codable {
    let id: String
    let appleUserID: String?
    let nickname: String
    let email: String?
    let englishLevel: String
    let languageStyle: String
    let availableGenerations: Int

    enum CodingKeys: String, CodingKey {
        case id
        case appleUserID = "apple_user_id"
        case nickname
        case email
        case englishLevel = "english_level"
        case languageStyle = "language_style"
        case availableGenerations = "available_generations"
    }
}

struct SupabaseMemoryRecord: Decodable {
    let id: String
    let imagePath: String
    let createdAt: Date
    let sentences: [SupabaseMemorySentenceRecord]

    enum CodingKeys: String, CodingKey {
        case id
        case imagePath = "image_url"
        case createdAt = "created_at"
        case sentences = "memory_sentences"
    }
}

struct SupabaseInsertedMemoryRecord: Decodable {
    let id: String
    let imagePath: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case imagePath = "image_url"
        case createdAt = "created_at"
    }
}

struct SupabaseMemorySentenceRecord: Decodable {
    let id: String
    let sortOrder: Int
    let english: String
    let chinese: String
    let isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sortOrder = "sort_order"
        case english
        case chinese
        case isFavorite = "is_favorite"
    }
}

struct SupabaseSentenceStudyQueueRecord: Decodable {
    let sentenceID: String
    let memoryID: String
    let english: String
    let chinese: String
    let imagePath: String
    let createdAt: Date
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: String?
    let nextReviewAt: Date?

    private enum CodingKeys: String, CodingKey {
        case sentenceID = "sentence_id"
        case memoryID = "memory_id"
        case english
        case chinese
        case imagePath = "image_url"
        case fallbackImagePath = "image_path"
        case createdAt = "created_at"
        case fallbackCreatedAt = "memory_created_at"
        case learningStep = "learning_step"
        case masteredReviewCount = "mastered_review_count"
        case correctCount = "correct_count"
        case wrongCount = "wrong_count"
        case lastResult = "last_result"
        case nextReviewAt = "next_review_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sentenceID = try container.decode(String.self, forKey: .sentenceID)
        memoryID = try container.decode(String.self, forKey: .memoryID)
        english = try container.decode(String.self, forKey: .english)
        chinese = try container.decode(String.self, forKey: .chinese)

        if let imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath) {
            self.imagePath = imagePath
        } else {
            imagePath = try container.decode(String.self, forKey: .fallbackImagePath)
        }

        if let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
            self.createdAt = createdAt
        } else {
            createdAt = try container.decode(Date.self, forKey: .fallbackCreatedAt)
        }

        learningStep = try container.decode(Int.self, forKey: .learningStep)
        masteredReviewCount = try container.decode(Int.self, forKey: .masteredReviewCount)
        correctCount = try container.decode(Int.self, forKey: .correctCount)
        wrongCount = try container.decode(Int.self, forKey: .wrongCount)
        lastResult = try container.decodeIfPresent(String.self, forKey: .lastResult)
        nextReviewAt = try container.decodeIfPresent(Date.self, forKey: .nextReviewAt)
    }
}

struct SupabaseSentenceStudyProgressRecord: Decodable {
    let id: String
    let sentenceID: String
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: String?
    let lastStudiedAt: Date?
    let nextReviewAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sentenceID = "sentence_id"
        case learningStep = "learning_step"
        case masteredReviewCount = "mastered_review_count"
        case correctCount = "correct_count"
        case wrongCount = "wrong_count"
        case lastResult = "last_result"
        case lastStudiedAt = "last_studied_at"
        case nextReviewAt = "next_review_at"
    }
}

struct SupabaseMergedSentenceStudyProgressRecord: Decodable {
    let sentenceID: String

    enum CodingKeys: String, CodingKey {
        case sentenceID = "sentence_id"
    }
}

struct SupabaseDeleteAccountResponse: Decodable {
    let success: Bool?
}

struct SupabaseGeneratedSentence: Decodable {
    let id: String?
    let english: String
    let chinese: String
    let isFavorite: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case english
        case chinese
        case isFavorite = "is_favorite"
    }
}

struct SupabaseGeneratedMemory: Decodable {
    let id: String
    let imagePath: String
    let createdAt: Date
    let sentences: [SupabaseGeneratedSentence]

    enum CodingKeys: String, CodingKey {
        case id
        case imagePath
        case createdAt
        case sentences
    }
}

struct SupabaseGenerateMemoryResult {
    let memory: MemoryEntry
    let remainingCredits: Int
    let guestJobID: String?
}

struct SupabaseGuestGenerationRecoveryResult {
    let guestJobID: String
    let memory: MemoryEntry
    let remainingCredits: Int
}

enum SupabaseEmailSignUpResult {
    case session(SupabaseSession)
    case requiresEmailConfirmation
}

struct SupabaseMigrateGuestCreditsResponse: Decodable {
    let profile: SupabaseProfileRecord
    let merged: Bool
    let guestUserID: String

    enum CodingKeys: String, CodingKey {
        case profile
        case merged
        case guestUserID
    }
}

enum SupabaseServiceError: LocalizedError {
    case missingConfiguration
    case invalidToken
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Supabase 配置缺失。"
        case .invalidToken:
            return "登录凭据无效。"
        case .invalidResponse:
            return "Supabase 返回了无法识别的数据。"
        case .apiError(let message):
            let normalized = message.lowercased()
            if normalized.contains("invalid login credentials") {
                return "邮箱或密码不正确。"
            }
            if normalized.contains("email not confirmed") ||
                normalized.contains("email_not_confirmed") {
                return "请先前往邮箱完成验证后再登录。"
            }
            if normalized.contains("user already registered") {
                return "该邮箱已注册，请直接登录。"
            }
            if normalized.contains("otp_expired") ||
                normalized.contains("token has expired") ||
                normalized.contains("expired otp") ||
                normalized.contains("expired token") {
                return "验证码已过期，请重新获取。"
            }
            if normalized.contains("invalid otp") ||
                normalized.contains("otp is invalid") ||
                normalized.contains("invalid token") ||
                normalized.contains("token is invalid") ||
                normalized.contains("invalid grant") ||
                normalized.contains("email link is invalid") {
                return "验证码不正确。"
            }
            if normalized.contains("password should be at least") ||
                normalized.contains("password must be at least") {
                return "密码长度不足，请至少输入 6 位。"
            }
            if normalized.contains("signup is disabled") {
                return "当前暂不支持邮箱注册。"
            }
            if normalized.contains("generation_banned") ||
                normalized.contains("当前账号暂时无法生成") {
                return "当前账号暂时无法生成，请稍后再试。"
            }
            if normalized.contains("generation_policy_violation") ||
                normalized.contains("这张图片暂时无法生成") {
                return "这张图片暂时无法生成，请更换图片后再试。"
            }
            if normalized.contains("image_moderation_unavailable") ||
                normalized.contains("图片安全检查失败") {
                return "图片安全检查失败，请稍后再试。"
            }
            if normalized.contains("too many requests") ||
                normalized.contains("rate limit") ||
                normalized.contains("rate_limit") ||
                normalized.contains("429") {
                return "当前使用人数过多，请稍后重试。"
            }
            if normalized.contains("engine overloaded") ||
                normalized.contains("service unavailable") ||
                normalized.contains("overloaded") {
                return "当前生成服务较忙，请稍后再试。"
            }
            if normalized.contains("upload image failed") ||
                normalized.contains("upload failed") ||
                normalized.contains("storage") && normalized.contains("upload") {
                return "图片上传失败，请稍后重试。"
            }
            if normalized.contains("insert memory failed") ||
                normalized.contains("insert sentences failed") ||
                normalized.contains("update credits failed") ||
                normalized.contains("insert transaction failed") ||
                normalized.contains("memory save failed") ||
                normalized.contains("save memory failed") {
                return "结果保存失败，请稍后重试。"
            }
            if normalized.contains("request time out") ||
                normalized.contains("request timed out") ||
                normalized.contains("timed out") ||
                normalized.contains("timeout") {
                return "当前使用人数过多，请稍后重试。"
            }
            if normalized.contains("bad gateway") ||
                normalized.contains("gateway") ||
                normalized.contains("服务网关异常") {
                return "当前生成服务异常，请稍后重试。"
            }
            if normalized.contains("network connection was lost") ||
                normalized.contains("connection was lost") ||
                normalized.contains("network connection") && normalized.contains("lost") {
                return "网络连接已中断，请回到前台并重试。"
            }
            if normalized.contains("data couldn’t be read because it is missing") ||
                normalized.contains("data couldn't be read because it is missing") {
                return "服务返回不完整，请稍后重试。"
            }
            if normalized.contains("data couldn’t be read because it isn’t in the correct format") ||
                normalized.contains("data couldn't be read because it isn't in the correct format") {
                return "服务返回格式异常，请稍后重试。"
            }
            return message
        }
    }
}
