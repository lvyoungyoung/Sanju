import Foundation

enum NicknameValidationError: LocalizedError {
    case empty
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入昵称。"
        case .tooLong:
            return "昵称长度不能超过 20 个字符。"
        }
    }
}

enum NicknameValidator {
    static func normalize(_ nickname: String) -> String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ nickname: String) throws -> String {
        let trimmed = normalize(nickname)

        guard !trimmed.isEmpty else {
            throw NicknameValidationError.empty
        }

        guard trimmed.count <= 20 else {
            throw NicknameValidationError.tooLong
        }

        return trimmed
    }
}
