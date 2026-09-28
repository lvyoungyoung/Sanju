import Foundation

enum MemoryIdentity {
    static func matches(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        // Generation recovery and guest migration preserve the memory ID.
        // Equal sentences (or image bytes) do not identify the same generation.
        lhs.id == rhs.id
    }

    static func isContentComplete(_ memory: MemoryEntry) -> Bool {
        guard memory.sentences.count == 3 || memory.sentences.count == 6 else { return false }

        return memory.sentences.allSatisfy {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
