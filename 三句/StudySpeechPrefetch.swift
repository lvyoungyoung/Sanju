import Foundation

/// Uses the same cache and in-flight request as album playback, but prepares
/// the current question silently instead of the next five album cards.
@MainActor
final class StudySpeechPrefetch {
    nonisolated deinit {}

    struct Context: Equatable {
        let text: String
        let ownerID: String?
        let enabled: Bool
    }

    private let speech: SpeechService
    private var scopeID: UUID?
    private var ownerID: String?

    init(speech: SpeechService) {
        self.speech = speech
    }

    func update(_ context: Context) {
        if scopeID != nil, ownerID != context.ownerID {
            end()
        }
        guard context.enabled else {
            if let scopeID { speech.pauseAlbumSpeechPrefetch(id: scopeID) }
            return
        }
        if scopeID == nil {
            scopeID = speech.beginAlbumSpeechPrefetch()
            ownerID = context.ownerID
        }
        guard let scopeID else { return }
        // No sentence is playing yet. Put this question first in the silent queue.
        speech.updateAlbumSpeechPrefetch(id: scopeID, current: "", upcoming: [context.text], enabled: true)
    }

    func end() {
        if let scopeID { speech.endAlbumSpeechPrefetch(id: scopeID) }
        scopeID = nil
        ownerID = nil
    }
}
