import AVFoundation
import Foundation

final class SpeechService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession = AVAudioSession.sharedInstance()

    func speak(_ text: String) {
        configureAudioSessionIfNeeded()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: normalizedSpeechText(from: text))
        utterance.voice = preferredVoice()
        utterance.rate = 0.42
        utterance.pitchMultiplier = 1.02
        utterance.volume = 1
        utterance.prefersAssistiveTechnologySettings = true
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.08
        synthesizer.speak(utterance)
    }

    private func configureAudioSessionIfNeeded() {
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
        } catch {
            // Keep speech available even if audio session configuration fails.
        }
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let preferredIdentifiers = [
            "com.apple.voice.enhanced.en-US.Samantha",
            "com.apple.voice.enhanced.en-US.Alex",
            "com.apple.voice.compact.en-US.Samantha"
        ]

        for identifier in preferredIdentifiers {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private func normalizedSpeechText(from text: String) -> String {
        text
            .replacingOccurrences(of: " i ", with: " I ")
            .replacingOccurrences(of: ",", with: ", ")
            .replacingOccurrences(of: ".", with: ". ")
            .replacingOccurrences(of: "!", with: "! ")
            .replacingOccurrences(of: "?", with: "? ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
