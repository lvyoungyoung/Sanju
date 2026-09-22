import AVFoundation
import Foundation

// All mutable state and blocking AVAudioSession calls are confined to this queue.
// Do not run these calls on MainActor or Swift's cooperative executor.
nonisolated final class SpeechAudioSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cc.sanju.speech-audio-session")
    private var isActive = false

    func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.isActive {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                        try session.setActive(true)
                        self.isActive = true
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deactivate() {
        queue.async {
            guard self.isActive else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.isActive = false
            } catch {
#if DEBUG
                print("[SpeechFlow] Audio session deactivation failed: \(error.localizedDescription)")
#endif
            }
        }
    }
}
