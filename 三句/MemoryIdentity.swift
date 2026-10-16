import Foundation

enum MemoryIdentity {
    static func matches(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        // Generation recovery and guest migration preserve the memory ID.
        // Equal sentences (or image bytes) do not identify the same generation.
        lhs.id == rhs.id
    }

    static func isContentComplete(_ memory: MemoryEntry) -> Bool {
        guard [3, 6, 12].contains(memory.sentences.count) else { return false }
        if memory.sentences.contains(where: { $0.dialogue != nil }) || memory.sentences.count == 12 {
            guard memory.sentences.count == 12,
                  memory.sentences.allSatisfy({ $0.dialogue?.isValid == true }),
                  memory.sentences.dialogueGroups.count == 6,
                  memory.sentences.dialogueGroups.allSatisfy({ $0.sentences.count == 2 }) else { return false }
        }

        return memory.sentences.allSatisfy {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
