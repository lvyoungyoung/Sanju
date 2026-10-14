import CryptoKit
import Foundation

struct SentenceLearningMaterial: Codable, Hashable, Sendable {
    struct Segment: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable {
            case word, particle, phrase, punctuation, whitespace
        }

        let id: String
        let surface: String
        var reading: String? = nil
        let kind: Kind
        let canBlank: Bool
    }

    var schemaVersion: Int = 1
    let textDigest: String
    var policyVersion: Int = 1
    let segments: [Segment]

    enum ValidationError: Error, Equatable {
        case unsupportedVersion, invalidDigest, invalidSegments, invalidReading, materialRequired
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func validate(targetText: String, language: LearningLanguage) throws {
        guard schemaVersion == 1, policyVersion == 1 else { throw ValidationError.unsupportedVersion }
        guard textDigest == Self.digest(targetText) else { throw ValidationError.invalidDigest }
        // Swift String equality normalizes Unicode; the wire contract instead requires exact UTF-8.
        guard !segments.isEmpty, segments.count <= 512, targetText.utf8.count <= 16_384,
              segments.map(\.surface).joined().utf8.elementsEqual(targetText.utf8),
              Set(segments.map(\.id)).count == segments.count else {
            throw ValidationError.invalidSegments
        }
        for segment in segments {
            guard !segment.id.isEmpty, segment.id.utf8.count <= 128, !segment.surface.isEmpty,
                  !(segment.canBlank && [.punctuation, .whitespace].contains(segment.kind)) else {
                throw ValidationError.invalidSegments
            }
            if segment.kind == .whitespace && !segment.surface.allSatisfy(\.isWhitespace) {
                throw ValidationError.invalidSegments
            }
            if segment.canBlank && !segment.surface.contains(where: { $0.isLetter || $0.isNumber }) {
                throw ValidationError.invalidSegments
            }
            if let reading = segment.reading {
                guard language.rawValue == "ja", !reading.isEmpty, reading.utf8.count <= 512,
                      segment.kind != .whitespace, segment.kind != .punctuation,
                      reading.unicodeScalars.allSatisfy({ scalar in
                          (0x3041...0x3096).contains(scalar.value) ||
                          (0x3099...0x309E).contains(scalar.value) ||
                          (0x30A1...0x30FA).contains(scalar.value) ||
                          (0x30FC...0x30FE).contains(scalar.value)
                      }) else { throw ValidationError.invalidReading }
            }
        }
    }

    /// A fixed local fallback only for historical English, never OS-dependent Japanese tokenization.
    static func legacyEnglish(targetText: String) -> Self {
        let characters = Array(targetText)
        var segments: [Segment] = []
        var index = 0
        while index < characters.count {
            let start = index
            let first = characters[index]
            let kind: Segment.Kind = first.isWhitespace ? .whitespace :
                (first.isLetter || first.isNumber ? .word : .punctuation)
            index += 1
            while index < characters.count {
                let next = characters[index]
                if kind == .whitespace && next.isWhitespace { index += 1; continue }
                if kind == .word {
                    if next.isLetter || next.isNumber { index += 1; continue }
                    if ["'", "’", "-"].contains(next), index + 1 < characters.count,
                       characters[index + 1].isLetter { index += 1; continue }
                }
                break
            }
            let surface = String(characters[start..<index])
            segments.append(Segment(id: "s\(segments.count)", surface: surface, kind: kind,
                                    canBlank: kind == .word && surface.contains(where: \.isLetter)))
        }
        return Self(textDigest: digest(targetText), segments: segments)
    }
}
