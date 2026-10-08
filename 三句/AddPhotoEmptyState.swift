import SwiftUI

enum PhotoContentState: Equatable {
    case content, loading, empty, failed

    static func resolve(hasContent: Bool, isLoading: Bool, hasError: Bool = false) -> Self {
        if hasContent { return .content }
        if isLoading { return .loading }
        return hasError ? .failed : .empty
    }
}

struct ContentLoadFailureState: View {
    let retry: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .accessibilityHidden(true)
            Text(L10n.string("content.load_failed.message", "暂时无法加载内容，请检查网络后重试。"))
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button(L10n.string("content.load_failed.retry", "重新加载"), action: retry)
                .buttonStyle(.bordered)
                .tint(AppPalette.accentText)
        }
        .foregroundStyle(AppTextColor.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxLarge)
    }
}

struct AddPhotoEmptyState: View {
    enum Destination: CaseIterable {
        case memories, study

        var title: String {
            switch self {
            case .memories: L10n.string("memories.empty.title", "还没有回忆")
            case .study: L10n.string("study.empty.photo_title", "从一张照片开始学习")
            }
        }
    }

    let destination: Destination
    let onAddPhoto: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.xLarge) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AppPalette.accentText)
                .frame(height: 96)
                .accessibilityHidden(true)

            VStack(spacing: AppSpacing.medium) {
                Text(destination.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTextColor.primary)
                Text(L10n.string("content.empty.add_photo_message", "添加一张你想记住的照片，让它变成可以反复学习的英语。"))
                    .font(.subheadline)
                    .foregroundStyle(AppTextColor.secondary)
                    .lineSpacing(4)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320)

            Button(action: onAddPhoto) {
                Label(L10n.string("content.empty.add_photo", "添加照片"), systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppPalette.onAccent)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 240, minHeight: AppControlHeight.prominent)
                    .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium))
            }
            .buttonStyle(StudioPressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxLarge)
    }
}
