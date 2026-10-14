import Foundation
import XCTest
@testable import 三句

@MainActor
final class MultilingualSpeechExplanationTests: XCTestCase {
    private func request(target: LearningLanguage = .japanese, support: SupportLanguage = .english,
                         translation: SupportLanguage = .simplifiedChinese, contentVersion: Int = 1,
                         generate: Bool = false) -> SentenceExplanationRequestV3 {
        .init(sentenceID: UUID(), targetText: "A", translationText: "B", targetLanguage: target,
              translationLanguage: translation, teachingLocale: target.teachingLocale,
              contentVersion: contentVersion, contentSchemaVersion: 2, explanationLanguage: support,
              exampleTranslationLanguage: support, generate: generate)
    }

    private func explanation(target: LearningLanguage = .japanese, support: SupportLanguage = .english) -> SentenceExplanation {
        .init(version: 3, points: [.init(title: "A", explanation: "Useful expression",
            example: .init(targetText: "Example", translationText: "Translation"))],
            targetLanguage: target, explanationLanguage: support, exampleTranslationLanguage: support)
    }

    func testGuestRequestEncodesNestedSourceWithoutLegacyFields() throws {
        let data = try JSONEncoder().encode(request())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try XCTUnwrap(body["source"] as? [String: Any])
        XCTAssertEqual(source["targetLanguage"] as? String, "ja")
        XCTAssertEqual(source["teachingLocale"] as? String, "ja-JP")
        XCTAssertEqual(source["contentSchemaVersion"] as? Int, 2)
        XCTAssertEqual(body["generate"] as? Bool, false)
        XCTAssertEqual(body["explanationLanguage"] as? String, "en")
        XCTAssertNil(body["english"])
        XCTAssertNil(body["targetText"])
    }

    func testExplanationCacheSeparatesEveryContentIdentityDimension() {
        let key = request().cacheKey(owner: "USER", environment: "production")
        XCTAssertEqual(key, request(generate: true).cacheKey(owner: "user", environment: "production"))
        XCTAssertNotEqual(key, request().cacheKey(owner: "other", environment: "production"))
        XCTAssertNotEqual(key, request().cacheKey(owner: "user", environment: "staging"))
        XCTAssertNotEqual(key, request(target: .spanish).cacheKey(owner: "user", environment: "production"))
        XCTAssertNotEqual(key, request(support: .simplifiedChinese).cacheKey(owner: "user", environment: "production"))
        XCTAssertNotEqual(key, request(translation: .english).cacheKey(owner: "user", environment: "production"))
        XCTAssertNotEqual(key, request(contentVersion: 2).cacheKey(owner: "user", environment: "production"))
    }

    func testSchemaThreeValidatesReturnedLanguageAndGenericExampleFields() throws {
        XCTAssertTrue(request().accepts(explanation()))
        XCTAssertFalse(request().accepts(explanation(target: .spanish)))
        XCTAssertFalse(request().accepts(explanation(support: .simplifiedChinese)))
        let raw = try JSONEncoder().encode(explanation())
        let restored = try JSONDecoder().decode(SentenceExplanation.self, from: raw)
        XCTAssertEqual(restored, explanation())
        XCTAssertTrue(restored.isValid)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("\"english\""))
        let mixed = SentenceExplanation(version: 3, points: [.init(title: "A", explanation: "B",
            example: .init(english: "C", chinese: "D"))], targetLanguage: .japanese,
            explanationLanguage: .english, exampleTranslationLanguage: .english)
        XCTAssertFalse(mixed.isValid)
    }

    func testUnsupportedPairsFailBeforeGenerationAndLegacyExamplesAreNotRelabeled() {
        XCTAssertFalse(request(target: .french, support: .japanese).isValid)
        XCTAssertTrue(request(target: .english, support: .japanese).isValid)
        XCTAssertNil(request(target: .english, support: .english).legacyRequest)
        let legacyInput = request(target: .english, support: .simplifiedChinese)
        let legacy = SentenceExplanation(version: 2, points: [.init(title: "A", explanation: "B",
            example: .init(english: "C", chinese: "D"))])
        XCTAssertNotNil(legacyInput.legacyRequest)
        let adapted = legacyInput.adaptingLegacy(legacy)
        XCTAssertEqual(adapted?.exampleTranslationLanguage, .simplifiedChinese)
        XCTAssertTrue(adapted.map(legacyInput.accepts) ?? false)
        XCTAssertNil(request().adaptingLegacy(legacy))
    }

    func testGenericCacheReopensOfflineAndDoesNotCrossSupportLanguages() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SentenceExplanationCache(directory: directory)
        let key = request().cacheKey(owner: "user", environment: "test")
        await cache.save(explanation(), key: key)
        let restored = await SentenceExplanationCache(directory: directory).load(key: key)
        XCTAssertEqual(restored, explanation())
        let other = await cache.load(key: request(support: .simplifiedChinese).cacheKey(owner: "user", environment: "test"))
        XCTAssertNil(other)
    }

    func testVoiceSettingsSummaryOnlyNamesSelectedVoiceForEnglish() {
        for voice in SpeechVoice.allCases {
            XCTAssertTrue(SpeechSettingsView.voiceSummary(for: .english, voice: voice).contains(voice.rawValue))
        }
        for language in [LearningLanguage.japanese, .spanish, .french] {
            let summaries = SpeechVoice.allCases.map { SpeechSettingsView.voiceSummary(for: language, voice: $0) }
            XCTAssertEqual(Set(summaries).count, 1)
            for voice in SpeechVoice.allCases {
                XCTAssertFalse(summaries[0].contains(voice.rawValue))
            }
        }
    }

    func testSpeechRequestsUseHistoricalSentenceContextNotEnglishVoicePreference() {
        let speech = SpeechService()
        speech.ownerProvider = { "owner" }
        speech.accountRevisionProvider = { 5 }
        speech.applyVoice(.dean)
        let context = MemoryContentContext(targetLanguage: .japanese, translationLanguage: .english,
                                           teachingLocale: .standardJapanese)
        let sentence = SentenceRecord(english: "Japanese target", chinese: "English translation")
        let speechRequest = speech.request(sentence: sentence, context: context)
        XCTAssertEqual(speechRequest.language, .japanese)
        XCTAssertEqual(speechRequest.teachingLocale, .standardJapanese)
        XCTAssertEqual(speechRequest.descriptor.voice, "coral")
        XCTAssertEqual(speechRequest.accountRevision, 5)
        XCTAssertTrue(speechRequest.isValid)
        XCTAssertNil(speechRequest.preferredSystemLocale(available: ["en-US", "fr-FR"]))
        XCTAssertEqual(speechRequest.preferredSystemLocale(available: ["en-US", "ja-JP"]), "ja-JP")
        XCTAssertEqual(speech.request(sentence: sentence, context: .legacyEnglish).descriptor.legacyVoice, .dean)
    }

    func testUnknownDescriptorCannotReadCachedAudio() async throws {
        let descriptor = SpeechDescriptor(profileID: "en-mia", profileRevision: 99, language: .english,
            teachingLocale: .americanEnglish, locale: "en-US", provider: "mimo", model: "mimo-v2.5-tts",
            voice: "Mia", audioFormat: "pcm16le", sampleRate: 24_000, channels: 1, promptVersion: 2)
        let input = SpeechRequest(text: "Hello", language: .english, teachingLocale: .americanEnglish,
                                  owner: "owner", descriptor: descriptor)
        XCTAssertFalse(input.isValid)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SpeechAudioCache(directory: directory)
        await cache.save(Data([0, 0]), key: SpeechAudioCache.key(request: input, environment: "test"))
        let audio = await cache.load(request: input, environment: "test")
        XCTAssertNil(audio)
        XCTAssertNil(SpeechAudioCache.legacyKey(request: input, environment: "test"))
    }

    func testPlaybackIndicatorDoesNotMatchIdenticalTextFromAnotherLanguage() {
        let english = SpeechRequest.english("A", owner: "user")
        let french = SpeechRequest(text: "A", language: .french, teachingLocale: .franceFrench, owner: "user")
        XCTAssertEqual(SpeechPlaybackState(request: french, activeRequest: english, activeText: "A", loadingText: "A"), .idle)
        XCTAssertEqual(SpeechPlaybackState(request: french, activeRequest: french, activeText: "A", loadingText: "A"), .loading)
    }

    func testDescriptorMustArriveBeforeAudioAndMatchExactly() throws {
        let expected = SpeechDescriptor.candidate(language: .japanese, teachingLocale: .standardJapanese)
        var stream = SpeechAudioStream(expectedDescriptor: expected)
        XCTAssertThrowsError(try stream.consume(#"{"type":"audio","data":"AAAAAA=="}"#))
        let encoded = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        XCTAssertNil(try stream.consume("{\"type\":\"descriptor\",\"descriptor\":\(encoded)}"))
        XCTAssertEqual(try stream.consume(#"{"type":"audio","data":"AAAAAA=="}"#), Data([0, 0, 0, 0]))
        XCTAssertNil(try stream.consume(#"{"type":"done"}"#))
        XCTAssertTrue(stream.isComplete)
        var mismatch = SpeechAudioStream(expectedDescriptor: .english())
        XCTAssertThrowsError(try mismatch.consume("{\"type\":\"descriptor\",\"descriptor\":\(encoded)}"))
    }

    func testReadingRequiresJapaneseAndMatchingContentDigest() {
        let material = SentenceLearningMaterial(textDigest: SentenceLearningMaterial.digest("猫です。"), segments: [
            .init(id: "0", surface: "猫", reading: "ねこ", kind: .word, canBlank: true),
            .init(id: "1", surface: "です", kind: .word, canBlank: true),
            .init(id: "2", surface: "。", kind: .punctuation, canBlank: false)
        ])
        let sentence = SentenceRecord(targetText: "猫です。", translationText: "A cat.", learningMaterial: material)
        let context = MemoryContentContext(targetLanguage: .japanese, translationLanguage: .english,
                                           teachingLocale: .standardJapanese)
        XCTAssertEqual(SentenceReadingView.reading(sentence: sentence, context: context), "ねこです。")
        XCTAssertNil(SentenceReadingView.reading(sentence: sentence, context: .legacyEnglish))
        let stale = SentenceRecord(targetText: "犬です。", translationText: "A dog.", learningMaterial: material)
        XCTAssertNil(SentenceReadingView.reading(sentence: stale, context: context))
    }

    func testWidgetSnapshotUsesGenericLanguageFields() throws {
        let item = MemoryWidgetSnapshotStore.Item(id: "sentence", memoryID: "memory", createdAt: .now,
            targetText: "Bonjour", translationText: "Hello", targetLanguage: "fr", translationLanguage: "en",
            teachingLocale: "fr-FR", contentVersion: 1, imageFileName: nil)
        let data = try JSONEncoder().encode(MemoryWidgetSnapshotStore.Snapshot(generatedAt: .now, items: [item]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        let rows = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["targetText"] as? String, "Bonjour")
        XCTAssertEqual(rows[0]["targetLanguage"] as? String, "fr")
        XCTAssertNil(rows[0]["english"])
    }

    func testMixedLanguageAlbumRetainsContextForEachLookaheadItem() {
        let french = MemoryContentContext(targetLanguage: .french, translationLanguage: .english, teachingLocale: .franceFrench)
        let memories = [MemoryEntry(imageData: Data(), sentences: [SentenceRecord(english: "A", chinese: "B")]),
                        MemoryEntry(imageData: Data(), sentences: [SentenceRecord(english: "A", chinese: "B")], context: french)]
        let items = AlbumFlipItem.makeItems(from: memories)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.context.targetLanguage), [.english, .french])
    }

    func testLookaheadDoesNotDeduplicateIdenticalTextAcrossLanguages() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let complete = expectation(description: "Both language requests fetched")
        complete.expectedFulfillmentCount = 2
        var fetched: [SpeechRequest] = []
        let queue = AlbumSpeechPrefetcher(cache: SpeechAudioCache(directory: directory), namespace: "test") { request, receive in
            fetched.append(request.speech)
            receive(Data([0, 0]))
            complete.fulfill()
            return Data([0, 0])
        }
        defer { queue.cancelAll() }
        let english = SpeechRequest.english("A", owner: "owner")
        let french = SpeechRequest(text: "A", language: .french, teachingLocale: .franceFrench, owner: "owner")
        queue.updateWindow(current: nil, upcoming: [english, french, french], enabled: true)
        await fulfillment(of: [complete], timeout: 3)
        XCTAssertEqual(fetched, [english, french])
    }

    func testAccountRevisionChangeRejectsStaleSameOwnerPlayback() {
        let speech = SpeechService()
        speech.ownerProvider = { "same-owner" }
        var revision = 1
        speech.accountRevisionProvider = { revision }
        let original = speech.request(text: "A", context: .legacyEnglish)
        speech.speak(original)
        XCTAssertEqual(speech.activeRequest, original)
        revision = 2
        speech.accountDidChange()
        speech.speak(original)
        XCTAssertNil(speech.activeRequest)
        let fresh = speech.request(text: "A", context: .legacyEnglish)
        XCTAssertNotEqual(original, fresh)
        speech.speak(fresh)
        XCTAssertEqual(speech.activeRequest, fresh)
        speech.stop()
    }

    func testResetOnSupportLanguageChangeDiscardsLateExplanation() async {
        let model = SentenceExplanationModel()
        var continuation: CheckedContinuation<SentenceExplanation?, Never>?
        let started = expectation(description: "Old language lookup started")
        let old = Task {
            await model.load(generate: false) {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.reset()
        await model.load(generate: false) { self.explanation(support: .simplifiedChinese) }
        continuation?.resume(returning: explanation())
        await old.value
        XCTAssertEqual(model.explanation?.explanationLanguage, .simplifiedChinese)
        XCTAssertFalse(model.isGenerating)
    }
}
