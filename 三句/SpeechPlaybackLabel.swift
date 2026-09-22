import SwiftUI

struct SpeechPlaybackLabel: View {
    @ObservedObject var speech: SpeechService
    let text: String
    var title: String? = nil
    var icon = "play.fill"

    private var isLoading: Bool {
        speech.loadingText == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: icon)
            }
            if let title { Text(title) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading
            ? L10n.string("speech.loading", "正在准备朗读")
            : title ?? L10n.string("new.result.play", "播放"))
    }
}

struct SentencePlaybackButton: View {
    let speech: SpeechService
    let text: String

    var body: some View {
        Button { speech.speak(text) } label: {
            SpeechPlaybackLabel(speech: speech, text: text, title: L10n.string("new.result.play", "播放"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTextColor.secondary)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(AppSurfaceColor.elevated, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }
}
