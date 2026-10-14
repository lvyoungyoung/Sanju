import CryptoKit
import Foundation

struct StudyQuestionContent {
    let targetText: String
    let tokens: [SentenceStudyToken]
    let wordBank: [SentenceStudyWordBankItem]
    let blankIDs: [UUID]
    let seed: UInt64
    let policyVersion: Int

    func isCorrectWord(_ word: SentenceStudyWordBankItem, for blankID: UUID) -> Bool {
        guard let expected = wordBank.first(where: { $0.blankID == blankID }) else { return false }
        return word.text.utf8.elementsEqual(expected.text.utf8)
    }
}

enum StudyQuestionBuilder {
    static func build(targetText: String, language: LearningLanguage,
                      material: SentenceLearningMaterial?, seed: UInt64 = 0) throws -> StudyQuestionContent {
        let material: SentenceLearningMaterial = try material ?? {
            guard language.rawValue == "en" else { throw SentenceLearningMaterial.ValidationError.materialRequired }
            return SentenceLearningMaterial.legacyEnglish(targetText: targetText)
        }()
        try material.validate(targetText: targetText, language: language)
        var random = StudySeedGenerator(state: seed)
        let candidates = material.segments.indices.filter { material.segments[$0].canBlank }
        let desired = StudyLanguagePolicy.desiredBlankCount(candidateCount: candidates.count)
        var selected: [Int] = []
        for priority in 0...2 {
            let eligible = candidates.filter { StudyLanguagePolicy.priority(for: material.segments[$0], language: language) == priority }
            let count = min(desired - selected.count, eligible.count)
            if count > 0 {
                for bucket in 0..<count {
                    let lower = bucket * eligible.count / count
                    let upper = (bucket + 1) * eligible.count / count
                    selected.append(eligible[lower + Int(random.next() % UInt64(upper - lower))])
                }
            }
        }
        let selectedSet = Set(selected)
        let identity = "\(material.textDigest)|\(language.rawValue)|\(seed)|\(material.policyVersion)"
        var bank: [SentenceStudyWordBankItem] = []
        let tokens = material.segments.enumerated().map { index, segment in
            let blankID = selectedSet.contains(index) ? stableID("\(identity)|blank|\(segment.id)") : nil
            let wordID = blankID.map { _ in stableID("\(identity)|word|\(segment.id)") }
            if let blankID, let wordID {
                bank.append(SentenceStudyWordBankItem(id: wordID, blankID: blankID,
                                                     tokenIndex: index, text: segment.surface))
            }
            return SentenceStudyToken(id: stableID("\(identity)|token|\(segment.id)"), tokenIndex: index,
                                      prefix: "", answer: segment.surface, suffix: "", blankID: blankID,
                                      correctWordID: wordID, segmentIDs: [segment.id], reading: segment.reading)
        }
        let blankIDs = bank.map(\.blankID)
        // Explicit shuffle keeps restored questions independent of Swift's random implementation.
        if bank.count > 1 {
            for index in stride(from: bank.count - 1, through: 1, by: -1) {
                bank.swapAt(index, Int(random.next() % UInt64(index + 1)))
            }
        }
        return StudyQuestionContent(targetText: targetText, tokens: tokens, wordBank: bank,
                                    blankIDs: blankIDs, seed: seed, policyVersion: material.policyVersion)
    }

    private static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private struct StudySeedGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
