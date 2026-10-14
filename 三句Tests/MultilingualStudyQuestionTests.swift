import XCTest
@testable import 三句

final class MultilingualStudyQuestionTests: XCTestCase {
    private func language(_ code: String) -> LearningLanguage { LearningLanguage(rawValue: code)! }

    private func material(_ segments: [SentenceLearningMaterial.Segment]) -> SentenceLearningMaterial {
        SentenceLearningMaterial(textDigest: SentenceLearningMaterial.digest(segments.map(\.surface).joined()), segments: segments)
    }

    func testDigestIsSHA256OfExactUTF8() throws {
        XCTAssertEqual(SentenceLearningMaterial.digest("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(SentenceLearningMaterial.digest("é"), SentenceLearningMaterial.digest("e\u{301}"))
    }

    @MainActor
    func testLiveQuestionUsesQueueLanguageInsteadOfEnglishFallback() throws {
        let item = SentenceStudyQueueItem(sentenceID: UUID(), memoryID: UUID(), english: "湖で泳ぎます。",
            chinese: "翻译", imagePath: "", createdAt: .now, learningStep: 0, masteredReviewCount: 0,
            correctCount: 0, wrongCount: 0, lastResult: nil, nextReviewAt: nil,
            context: MemoryContentContext(targetLanguage: .japanese, translationLanguage: .simplifiedChinese,
                teachingLocale: .standardJapanese), learningMaterial: nil)
        XCTAssertFalse(SentenceStudyQuestion(item: item).isValid)
        XCTAssertTrue(SentenceStudyQuestion(item: item).tokens.isEmpty)
    }

    @MainActor
    func testSessionRetryKeepsEventIDTimestampAndLanguage() {
        let state = StudySessionState(language: .spanish, accountRevision: UUID(),
            timeZone: TimeZone(identifier: "America/Mexico_City")!, seed: 123)
        let id = UUID()
        let event = state.event(for: id)
        XCTAssertEqual(state.event(for: id).id, event.id)
        XCTAssertEqual(state.event(for: id).occurredAt, event.occurredAt)
        XCTAssertEqual(state.language, .spanish)
        XCTAssertEqual(state.seed, 123)
        XCTAssertEqual(state.timeZoneID, "America/Mexico_City")
    }

    func testEnglishFallbackPreservesWhitespaceContractionsAndGraphemes() throws {
        let text = "  I'm\tnear a café.\n👩🏽‍💻 🇫🇷 ❤️  "
        let question = try StudyQuestionBuilder.build(targetText: text, language: language("en"), material: nil, seed: 42)
        XCTAssertEqual(Array(question.tokens.map(\.displayText).joined().utf8), Array(text.utf8))
        XCTAssertTrue(question.wordBank.contains { $0.text == "near" })
        XCTAssertFalse(question.wordBank.contains { $0.text.contains("👩") })
        XCTAssertTrue(question.tokens.contains { $0.answer == "I'm" })
    }

    func testJapaneseUsesWholePhraseAndHidesEveryReadingWhenBlank() throws {
        let segments: [SentenceLearningMaterial.Segment] = [
            .init(id: "lake", surface: "湖", reading: "みずうみ", kind: .word, canBlank: true),
            .init(id: "particle", surface: "で", kind: .particle, canBlank: true),
            .init(id: "verb", surface: "泳いでいます", reading: "およいでいます", kind: .phrase, canBlank: true),
            .init(id: "stop", surface: "。", kind: .punctuation, canBlank: false)
        ]
        let text = segments.map(\.surface).joined()
        let question = try StudyQuestionBuilder.build(targetText: text, language: language("ja"), material: material(segments), seed: 9)
        XCTAssertEqual(question.tokens.map(\.displayText).joined(), text)
        XCTAssertEqual(Set(question.wordBank.map(\.text)), Set(["湖", "で", "泳いでいます"]))
        XCTAssertEqual(question.blankIDs.count, 3)
        for token in question.tokens where token.isBlank {
            XCTAssertNil(token.visibleReading())
            XCTAssertEqual(token.accessibilityText(blankLabel: "Blank"), "Blank")
            XCTAssertEqual(token.visibleReading(isAnswered: true), token.reading)
            XCTAssertEqual(token.accessibilityText(isAnswered: true, blankLabel: "Blank"), token.answer)
        }
        XCTAssertThrowsError(try StudyQuestionBuilder.build(targetText: text, language: language("ja"), material: nil))
    }

    func testAccentsElisionsRepeatedOptionsAndRestore() throws {
        for (code, text) in [("fr", "L’été, c'est à l'école. à"), ("es", "Él está aquí. sí sí")] {
            let segments = SentenceLearningMaterial.legacyEnglish(targetText: text).segments
            let input = material(segments)
            let first = try StudyQuestionBuilder.build(targetText: text, language: language(code), material: input, seed: 111)
            let second = try StudyQuestionBuilder.build(targetText: text, language: language(code), material: input, seed: 111)
            XCTAssertEqual(first.tokens.map(\.displayText).joined(), text)
            XCTAssertEqual(first.tokens.map(\.id), second.tokens.map(\.id))
            XCTAssertEqual(first.blankIDs, second.blankIDs)
            XCTAssertEqual(first.wordBank, second.wordBank)
        }
        let input = material([.init(id: "1", surface: "sí", kind: .word, canBlank: true),
                              .init(id: "space", surface: " ", kind: .whitespace, canBlank: false),
                              .init(id: "2", surface: "sí", kind: .word, canBlank: true)])
        let question = try StudyQuestionBuilder.build(targetText: "sí sí", language: language("es"), material: input)
        XCTAssertEqual(question.wordBank.count, 2)
        XCTAssertNotEqual(question.wordBank[0].id, question.wordBank[1].id)
        XCTAssertTrue(question.isCorrectWord(question.wordBank[0], for: question.wordBank[1].blankID))
        let wrong = SentenceStudyWordBankItem(id: UUID(), blankID: question.blankIDs[0], tokenIndex: 0, text: "si")
        XCTAssertFalse(question.isCorrectWord(wrong, for: question.blankIDs[0]))
    }

    func testMaterialRejectsRewritesVersionsDuplicateIDsAndAnswerBearingReadings() throws {
        let segment = SentenceLearningMaterial.Segment(id: "one", surface: "é", kind: .word, canBlank: true)
        var value = material([segment])
        XCTAssertThrowsError(try value.validate(targetText: "e", language: language("fr")))
        value.schemaVersion = 2
        XCTAssertThrowsError(try value.validate(targetText: "é", language: language("fr")))
        value.schemaVersion = 1
        value.policyVersion = 2
        XCTAssertThrowsError(try value.validate(targetText: "é", language: language("fr")))
        XCTAssertThrowsError(try material([segment, segment]).validate(targetText: "éé", language: language("fr")))
        let normalized = SentenceLearningMaterial(textDigest: SentenceLearningMaterial.digest("e\u{301}"), segments: [segment])
        XCTAssertThrowsError(try normalized.validate(targetText: "e\u{301}", language: language("fr")))
        let leaking = material([.init(id: "a", surface: "湖", reading: "lake", kind: .word, canBlank: true)])
        XCTAssertThrowsError(try leaking.validate(targetText: "湖", language: language("ja")))
        let punctuation = material([.init(id: "a", surface: "。", kind: .punctuation, canBlank: true)])
        XCTAssertThrowsError(try punctuation.validate(targetText: "。", language: language("ja")))
    }
}
