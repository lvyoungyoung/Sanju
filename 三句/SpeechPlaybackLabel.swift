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

    init(request: SpeechRequest, activeRequest: SpeechRequest?, activeText: String?, loadingText: String?) {
        guard request == activeRequest else { self = .idle; return }
        if loadingText == request.text { self = .loading }
        else if activeText == request.text { self = .playing }
        else { self = .idle }
    }
}

struct SpeechPlaybackLabel: View {
    @ObservedObject var speech: SpeechService
    let text: String
    var title: String? = nil
    var icon = "play.fill"
    var playingTitle: String? = nil
    var request: SpeechRequest? = nil

    var body: some View {
        let state = request.map {
            SpeechPlaybackState(request: $0, activeRequest: speech.activeRequest,
                                activeText: speech.activeText, loadingText: speech.loadingText)
        } ?? SpeechPlaybackState(text: text, activeText: speech.activeText, loadingText: speech.loadingText)
        SpeechPlaybackContent(
            state: state == .playing && playingTitle == nil ? .idle : state,
            title: title,
            icon: icon,
            playingTitle: playingTitle
        )
        .alert(L10n.string("speech.unavailable.title", "无法播放"), isPresented: Binding(
            get: {
                speech.playbackError != nil && (request.map { speech.playbackErrorRequest == $0 }
                    ?? (speech.playbackErrorRequest?.text == text))
            },
            set: { if !$0 { speech.dismissPlaybackError() } }
        )) {
            Button(L10n.string("common.ok", "好"), role: .cancel) { speech.dismissPlaybackError() }
        } message: {
            Text(L10n.string("speech.unavailable.message", "暂时无法播放此语言，请稍后重试，或在系统设置中下载对应语言的声音。"))
        }
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
    @ObservedObject var speech: SpeechService
    let text: String
    let request: SpeechRequest?

    init(speech: SpeechService, text: String) {
        self.speech = speech; self.text = text; request = nil
    }

    init(speech: SpeechService, request: SpeechRequest) {
        self.speech = speech; self.request = request; text = request.text
    }

    var body: some View {
        Button {
            if let request { speech.speak(request) } else { speech.speak(text) }
        } label: {
            SpeechPlaybackLabel(
                speech: speech,
                text: text,
                title: L10n.string("new.result.play", "播放"),
                playingTitle: L10n.string("new.result.playing", "播放中"),
                request: request
            )
        }
        .buttonStyle(SentenceActionButtonStyle(isEmphasized: true))
    }
}
