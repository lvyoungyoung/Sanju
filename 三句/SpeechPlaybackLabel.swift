import SwiftUI

enum SpeechPlaybackState: Equatable {
    case idle, loading, playing

    init(text: String, activeText: String?, loadingText: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, loadingText == text {
            self = .loading
        } else if !text.isEmpty, activeText == text {
            self = .playing
        } else {
            self = .idle
        }
    }
}

struct SpeechPlaybackLabel: View {
    @ObservedObject var speech: SpeechService
    let text: String
    var title: String? = nil
    var icon = "play.fill"
    var playingTitle: String? = nil

    var body: some View {
        let state = SpeechPlaybackState(text: text, activeText: speech.activeText, loadingText: speech.loadingText)
        SpeechPlaybackContent(
            state: state == .playing && playingTitle == nil ? .idle : state,
            title: title,
            icon: icon,
            playingTitle: playingTitle
        )
    }
}

struct SpeechPlaybackContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: SpeechPlaybackState
    let title: String?
    let icon: String
    let playingTitle: String?

    private var accessibilityStatus: String {
        switch state {
        case .idle: ""
        case .loading: L10n.string("speech.loading", "正在准备朗读")
        case .playing: playingTitle ?? L10n.string("speech.playing", "朗读中")
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch state {
                case .loading:
                    ProgressView().controlSize(.mini)
                case .playing:
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                case .idle:
                    Image(systemName: icon)
                }
            }
            .frame(width: 16, height: 16)
            if let title {
                // Reserve both titles so changing playback state never shifts the button.
                ZStack {
                    Text(title).opacity(state == .playing ? 0 : 1)
                    if let playingTitle {
                        Text(playingTitle).opacity(state == .playing ? 1 : 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? L10n.string("new.result.play", "播放"))
        .accessibilityValue(accessibilityStatus)
    }
}

struct SentencePlaybackButton: View {
    let speech: SpeechService
    let text: String

    var body: some View {
        Button { speech.speak(text) } label: {
            SpeechPlaybackLabel(
                speech: speech,
                text: text,
                title: L10n.string("new.result.play", "播放"),
                playingTitle: L10n.string("new.result.playing", "播放中")
            )
        }
        .buttonStyle(SentenceActionButtonStyle(isEmphasized: true))
    }
}
