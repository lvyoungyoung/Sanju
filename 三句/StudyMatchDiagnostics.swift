#if DEBUG
import Foundation

struct StudyMatchDiagnostics: Decodable {
    let scene_id: UUID
    let name: String
    let learning_topic_id: String?
    let threshold: Double
    let rule: String
    let query_model: String?
    let legacy_search_description: String?
    let total_sentences: Int
    let included_count: Int
    let rows: [Row]

    struct Row: Decodable {
        let sentence_id: UUID
        let english: String
        let expression_purpose: String?
        let sentence_model: String?
        let has_sentence_vector: Bool
        let has_purpose_vector: Bool
        let sentence_similarity: Double?
        let purpose_similarity: Double?
        let included: Bool
        let stored_source: String?
        let stored_score: Int?
        let current_source: String?
    }

    var logLines: [String] {
        var lines = [
            "[StudyMatch] BEGIN theme=\(Self.text(name)) id=\(scene_id) rule=\(rule) threshold=\(Self.score(threshold))",
            "[StudyMatch] queryModel=\(Self.text(query_model)) legacySearchDescription=\(Self.text(legacy_search_description))",
            "[StudyMatch] included=\(included_count) total=\(total_sentences) shown=\(rows.count) truncated=\(rows.count < total_sentences); included first, then highest similarity. Scores are similarities, not probabilities."
        ]
        if let learning_topic_id {
            lines.append("[StudyMatch] Category topic=\(Self.text(learning_topic_id)); inclusion uses categories, NOT the semantic threshold.")
        }
        for row in rows {
            let mismatch = learning_topic_id == nil && row.included != (row.current_source != nil)
            lines.append("[StudyMatch] sentence=\(row.sentence_id) included=\(row.included) storedSource=\(Self.text(row.stored_source)) storedScore=\(row.stored_score.map(String.init) ?? "none") currentSource=\(Self.text(row.current_source)) linkMismatch=\(mismatch)")
            lines.append("[StudyMatch]   English: \(Self.text(row.english))")
            lines.append("[StudyMatch]   Purpose: \(Self.text(row.expression_purpose))")
            lines.append("[StudyMatch]   original=\(Self.score(row.sentence_similarity)) purpose=\(Self.score(row.purpose_similarity)) vectors=\(row.has_sentence_vector)/\(row.has_purpose_vector) model=\(Self.text(row.sentence_model))")
        }
        lines.append("[StudyMatch] END theme=\(scene_id)")
        return lines
    }

    private static func score(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func text(_ value: String?) -> String {
        guard let value else { return "none" }
        return String(value.prefix(500)).components(separatedBy: .newlines).joined(separator: " ")
    }
}
#endif
