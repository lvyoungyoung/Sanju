import SwiftUI

extension Text {
    init(sentenceText: String, language: String) {
        var content = AttributedString(sentenceText)
        content.languageIdentifier = language
        self.init(content)
    }
}

struct SentenceReadingView: View {
    let sentence: SentenceRecord
    let context: MemoryContentContext
    var isEnabled = true

    static func reading(sentence: SentenceRecord, context: MemoryContentContext) -> String? {
        guard context.targetLanguage == .japanese, let material = sentence.learningMaterial,
              (try? material.validate(targetText: sentence.targetText, language: .japanese)) != nil,
              material.segments.contains(where: { $0.reading != nil }) else { return nil }
        return material.segments.map { $0.reading ?? $0.surface }.joined()
    }

    var body: some View {
        if isEnabled, let reading = Self.reading(sentence: sentence, context: context) {
            Text(sentenceText: reading, language: "ja-JP")
                .font(.subheadline)
                .foregroundStyle(AppTextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
