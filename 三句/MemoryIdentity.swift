import Foundation

enum MemoryIdentity {
    static func matches(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsContent = lhs.sentences.map { normalizedSentenceIdentity(for: $0) }
        let rhsContent = rhs.sentences.map { normalizedSentenceIdentity(for: $0) }
        return lhsContent == rhsContent
    }

    static func isContentComplete(_ memory: MemoryEntry) -> Bool {
        guard memory.sentences.count == 3 else { return false }

        return memory.sentences.allSatisfy {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func normalizedSentenceIdentity(for sentence: SentenceRecord) -> String {
        "\(normalizeSentenceComponent(sentence.english))\u{001F}\(normalizeSentenceComponent(sentence.chinese))"
    }

    private static func normalizeSentenceComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
