import Foundation
import SwiftUI

struct SentenceStudyQuestion {
    let item: SentenceStudyQueueItem
    let tokens: [SentenceStudyToken]
    let wordBank: [SentenceStudyWordBankItem]
    let blankIDs: [UUID]

    init(item: SentenceStudyQueueItem) {
        self.item = item

        let parts = item.english
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)

        let parsedWords = parts.enumerated().map { index, part in
            SentenceStudyParsedWord(tokenIndex: index, raw: part)
        }

        let blankIndices = SentenceStudyQuestion.selectedBlankIndices(from: parsedWords)
        let blankWords = blankIndices.map { index in
            SentenceStudyWordBankItem(
                id: UUID(),
                blankID: UUID(),
                tokenIndex: index,
                text: parsedWords[index].core
            )
        }

        let wordMap = Dictionary(uniqueKeysWithValues: blankWords.map { ($0.tokenIndex, $0) })

        self.tokens = parsedWords.map { parsedWord in
            if let blankWord = wordMap[parsedWord.tokenIndex] {
                return SentenceStudyToken(
                    id: UUID(),
                    tokenIndex: parsedWord.tokenIndex,
                    prefix: parsedWord.prefix,
                    answer: parsedWord.core,
                    suffix: parsedWord.suffix,
                    blankID: blankWord.blankID,
                    correctWordID: blankWord.id
                )
            }

            return SentenceStudyToken(
                id: UUID(),
                tokenIndex: parsedWord.tokenIndex,
                prefix: parsedWord.prefix,
                answer: parsedWord.core,
                suffix: parsedWord.suffix,
                blankID: nil,
                correctWordID: nil
            )
        }

        self.wordBank = blankWords.shuffled()
        self.blankIDs = blankWords.map(\.blankID)
    }

    func wordItem(for blankID: UUID) -> SentenceStudyWordBankItem? {
        wordBank.first(where: { $0.blankID == blankID })
    }

    func isCorrectWord(_ word: SentenceStudyWordBankItem, for blankID: UUID) -> Bool {
        guard let expectedWord = wordItem(for: blankID) else { return false }
        return word.text == expectedWord.text
    }

    func blankWidth(for word: SentenceStudyWordBankItem) -> CGFloat {
        max(66, CGFloat(word.text.count) * 16 + 22)
    }

    private static func selectedBlankIndices(from words: [SentenceStudyParsedWord]) -> [Int] {
        let alphaWords = words.filter(\.isAlphabetic)
        guard !alphaWords.isEmpty else { return [] }

        let desiredCount: Int
        switch alphaWords.count {
        case 0:
            desiredCount = 0
        case 1...2:
            desiredCount = alphaWords.count
        case 3...7:
            desiredCount = 3
        case 8...11:
            desiredCount = 4
        default:
            desiredCount = 5
        }

        let prepositions = alphaWords.filter(\.isPrepositionBlankCandidate).map(\.tokenIndex)
        let contentWords = alphaWords
            .filter { !$0.isPrepositionBlankCandidate && $0.isContentBlankCandidate }
            .map(\.tokenIndex)
        let fallback = alphaWords
            .filter { !$0.isPrepositionBlankCandidate && !$0.isContentBlankCandidate }
            .map(\.tokenIndex)

        var selected = randomizedDistributedSelection(from: prepositions, count: desiredCount)
        if selected.count < desiredCount {
            let excluded = Set(selected)
            let remainingContentWords = contentWords.filter { !excluded.contains($0) }
            selected.append(contentsOf: randomizedDistributedSelection(from: remainingContentWords, count: desiredCount - selected.count))
        }

        if selected.count < desiredCount {
            let excluded = Set(selected)
            let remainingFallback = fallback.filter { !excluded.contains($0) }
            selected.append(contentsOf: randomizedDistributedSelection(from: remainingFallback, count: desiredCount - selected.count))
        }

        return selected.sorted()
    }

    private static func randomizedDistributedSelection(from candidates: [Int], count: Int) -> [Int] {
        guard count > 0, !candidates.isEmpty else { return [] }
        if candidates.count <= count {
            return candidates
        }

        let bucketCount = min(count, candidates.count)
        var selected: [Int] = []
        var usedCandidates = Set<Int>()

        for bucketIndex in 0..<bucketCount {
            let lowerBound = bucketIndex * candidates.count / bucketCount
            let upperBound = ((bucketIndex + 1) * candidates.count / bucketCount) - 1
            let bucketCandidates = candidates[lowerBound...upperBound]
                .filter { !usedCandidates.contains($0) }

            if let candidate = bucketCandidates.randomElement() {
                selected.append(candidate)
                usedCandidates.insert(candidate)
            }
        }

        if selected.count < count {
            let remaining = candidates
                .filter { !usedCandidates.contains($0) }
                .shuffled()
                .prefix(count - selected.count)
            selected.append(contentsOf: remaining)
        }

        return selected.sorted()
    }
}

private struct SentenceStudyParsedWord {
    let tokenIndex: Int
    let raw: String
    let prefix: String
    let core: String
    let suffix: String

    init(tokenIndex: Int, raw: String) {
        self.tokenIndex = tokenIndex
        self.raw = raw

        let characters = Array(raw)
        let allowed = Self.allowedCharacters

        guard let start = characters.firstIndex(where: { allowed.contains($0.unicodeScalars.first!) }),
              let end = characters.lastIndex(where: { allowed.contains($0.unicodeScalars.first!) }),
              start <= end else {
            prefix = ""
            core = raw
            suffix = ""
            return
        }

        prefix = String(characters[..<start])
        core = String(characters[start...end])
        suffix = String(characters[(end + 1)...])
    }

    var isAlphabetic: Bool {
        core.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    var isPrepositionBlankCandidate: Bool {
        SentenceStudyParsedWord.prepositions.contains(core.lowercased())
    }

    var isContentBlankCandidate: Bool {
        let lowercased = core.lowercased()
        return isAlphabetic &&
            core.count >= 4 &&
            !SentenceStudyParsedWord.stopWords.contains(lowercased)
    }

    private static let allowedCharacters: CharacterSet = {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
    }()

    private static let stopWords: Set<String> = [
        "a", "am", "an", "and", "are", "as", "at", "be", "been", "being",
        "but", "by", "for", "from", "had", "has", "have", "he", "her", "his",
        "i", "in", "is", "it", "its", "me", "my", "of", "on", "or", "our",
        "she", "so", "that", "the", "their", "them", "there", "they", "this",
        "to", "up", "us", "very", "was", "we", "were", "with", "you", "your"
    ]

    private static let prepositions: Set<String> = [
        "about", "above", "across", "after", "against", "along", "among", "around",
        "at", "before", "behind", "below", "beneath", "beside", "between", "beyond",
        "by", "down", "during", "for", "from", "in", "inside", "into", "near",
        "of", "off", "on", "onto", "out", "outside", "over", "past", "through",
        "to", "toward", "towards", "under", "underneath", "until", "up", "upon",
        "with", "within", "without"
    ]
}

struct SentenceStudyToken: Identifiable {
    let id: UUID
    let tokenIndex: Int
    let prefix: String
    let answer: String
    let suffix: String
    let blankID: UUID?
    let correctWordID: UUID?

    var isBlank: Bool {
        blankID != nil
    }

    var displayText: String {
        prefix + answer + suffix
    }
}

struct SentenceStudyWordBankItem: Identifiable, Hashable {
    let id: UUID
    let blankID: UUID
    let tokenIndex: Int
    let text: String
}
