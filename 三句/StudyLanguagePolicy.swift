import Foundation

enum StudyLanguagePolicy {
    static let version = 1

    static func desiredBlankCount(candidateCount: Int) -> Int {
        switch candidateCount {
        case ...0: return 0
        case 1...2: return candidateCount
        case 3...7: return 3
        case 8...11: return 4
        default: return 5
        }
    }

    static func priority(for segment: SentenceLearningMaterial.Segment, language: LearningLanguage) -> Int {
        let word = segment.surface.lowercased()
        switch language.rawValue {
        case "en":
            if englishPrepositions.contains(word) { return 0 }
            return word.count >= 4 && !englishStopWords.contains(word) ? 1 : 2
        case "es":
            if spanishFunctionWords.contains(word) { return 0 }
            return segment.kind == .phrase ? 1 : 2
        case "fr":
            // An elision remains one original surface; no stripping of apostrophes or accents.
            if frenchFunctionWords.contains(word) { return 0 }
            return word.contains("'") || word.contains("’") || segment.kind == .phrase ? 1 : 2
        case "ja":
            return segment.kind == .particle ? 0 : (segment.kind == .phrase ? 1 : 2)
        default: return 2
        }
    }

    private static let englishPrepositions: Set<String> = Set("about above across after against along among around at before behind below beneath beside between beyond by down during for from in inside into near of off on onto out outside over past through to toward towards under underneath until up upon with within without".split(separator: " ").map(String.init))
    private static let englishStopWords: Set<String> = Set("a am an and are as at be been being but by for from had has have he her his i in is it its me my of on or our she so that the their them there they this to up us very was we were with you your".split(separator: " ").map(String.init))
    private static let spanishFunctionWords: Set<String> = Set("a ante bajo con contra de desde durante en entre hacia hasta para por sin sobre tras el la los las un una unos unas al del".split(separator: " ").map(String.init))
    private static let frenchFunctionWords: Set<String> = Set("à de dans par pour en vers avec sans sous sur entre chez le la les un une des du au aux".split(separator: " ").map(String.init))
}
