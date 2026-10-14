import Foundation
import SwiftUI

struct SentenceStudyQuestion {
    let item: SentenceStudyQueueItem
    let tokens: [SentenceStudyToken]
    let wordBank: [SentenceStudyWordBankItem]
    let blankIDs: [UUID]
    let isValid: Bool

    init(item: SentenceStudyQueueItem, targetText: String, language: LearningLanguage,
         material: SentenceLearningMaterial?, seed: UInt64) throws {
        let content = try StudyQuestionBuilder.build(targetText: targetText, language: language,
                                                     material: material, seed: seed)
        self.item = item
        tokens = content.tokens
        wordBank = content.wordBank
        blankIDs = content.blankIDs
        isValid = !content.blankIDs.isEmpty
    }

    init(item: SentenceStudyQueueItem, seed: UInt64 = 0) {
        self.item = item
        let content = try? StudyQuestionBuilder.build(targetText: item.targetText,
            language: item.context.targetLanguage, material: item.learningMaterial, seed: seed)
        tokens = content?.tokens ?? []
        wordBank = content?.wordBank ?? []
        blankIDs = content?.blankIDs ?? []
        isValid = !(content?.blankIDs.isEmpty ?? true)
    }

    func wordItem(for blankID: UUID) -> SentenceStudyWordBankItem? {
        wordBank.first(where: { $0.blankID == blankID })
    }

    func isCorrectWord(_ word: SentenceStudyWordBankItem, for blankID: UUID) -> Bool {
        guard let expectedWord = wordItem(for: blankID) else { return false }
        return word.text.utf8.elementsEqual(expectedWord.text.utf8)
    }

    func blankWidth(for word: SentenceStudyWordBankItem) -> CGFloat {
        max(66, min(280, CGFloat(word.text.count) * 20 + 22))
    }
}

struct SentenceStudyToken: Identifiable {
    let id: UUID
    let tokenIndex: Int
    let prefix: String
    let answer: String
    let suffix: String
    let blankID: UUID?
    let correctWordID: UUID?
    var segmentIDs: [String] = []
    var reading: String? = nil

    func visibleReading(isAnswered: Bool = false) -> String? {
        isBlank && !isAnswered ? nil : reading
    }

    func accessibilityText(isAnswered: Bool = false, blankLabel: String) -> String {
        if isBlank && !isAnswered { return blankLabel }
        return displayText
    }

    var isBlank: Bool { blankID != nil }
    var displayText: String { prefix + answer + suffix }
}

struct SentenceStudyWordBankItem: Identifiable, Hashable {
    let id: UUID
    let blankID: UUID
    let tokenIndex: Int
    let text: String
}
