import SwiftUI

struct SentenceActions: View {
    let speech: SpeechService
    let text: String
    let isFavorite: Bool
    let onFavorite: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var buttons: some View {
        SentencePlaybackButton(speech: speech, text: text)
        SentenceFavoriteButton(isFavorite: isFavorite, action: onFavorite)
    }
}

struct SentenceFavoriteButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .frame(width: 16, height: 16)
                ZStack {
                    Text(L10n.string("new.result.favorite", "收藏"))
                        .opacity(isFavorite ? 0 : 1)
                    Text(L10n.string("new.result.saved", "已收藏"))
                        .opacity(isFavorite ? 1 : 0)
                }
            }
        }
        .buttonStyle(SentenceActionButtonStyle(isEmphasized: isFavorite))
        .accessibilityLabel(isFavorite
            ? L10n.string("favorites.action.unfavorite", "取消收藏")
            : L10n.string("new.result.favorite", "收藏"))
        .accessibilityValue(isFavorite ? L10n.string("new.result.saved", "已收藏") : "")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}

struct SentenceActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    let isEmphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(isEmphasized ? AppPalette.accentText : AppTextColor.secondary)
            .tint(isEmphasized ? AppPalette.accentText : AppTextColor.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(minWidth: 110, minHeight: 44)
            .background(isEmphasized ? AppPalette.apricot : AppSurfaceColor.elevated, in: Capsule())
            .contentShape(Capsule())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
    }
}
