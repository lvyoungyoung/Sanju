import SwiftUI

struct StudySceneSuggestionSection: View {
    @ObservedObject var suggestions: StudySceneSuggestions
    let selectedTopicID: String?
    let onRefresh: () -> Void
    let onSelect: (LearningTopic) -> Void

    private var isLoading: Bool {
        suggestions.loadState == .idle || suggestions.loadState == .loading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                Text(L10n.string("study.scene.suggestions_title", "试试这些"))
                    .font(.system(size: AppFontSize.metadata, weight: .medium))
                    .foregroundStyle(AppTextColor.secondary)

                Spacer(minLength: AppSpacing.small)

                Button(action: onRefresh) {
                    Group {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: AppIconSize.compact, weight: .semibold))
                        }
                    }
                    .foregroundStyle(AppTextColor.secondary)
                    .frame(width: 32, height: 28)
                    .background(AppSurfaceColor.secondaryFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel(isLoading
                    ? L10n.string("study.scene.suggestions_loading", "正在获取推荐主题...")
                    : L10n.string("study.scene.refresh_suggestions", "换一批推荐"))
            }

            if suggestions.displayedTopics.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: AppFontSize.metadata))
                    .foregroundStyle(AppTextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                StudyFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(suggestions.displayedTopics) { topic in
                        Button { onSelect(topic) } label: {
                            Text(topic.title)
                                .font(.system(size: AppFontSize.metadata, weight: .medium))
                                .foregroundStyle(selectedTopicID == topic.id ? AppPalette.accent : AppTextColor.primary)
                                .padding(.horizontal, AppSpacing.medium)
                                .frame(height: 32)
                                .background(
                                    selectedTopicID == topic.id ? AppPalette.accent.opacity(0.14) : AppSurfaceColor.secondaryFill,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(selectedTopicID == topic.id ? AppPalette.accent.opacity(0.38) : AppStroke.subtle, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L10n.string("study.scene.suggestion_fill_hint", "填入学习主题"))
                    }
                }
                if suggestions.loadState == .failed {
                    Text(L10n.string("study.scene.suggestions_refresh_failed", "推荐更新失败，已保留原有推荐，可点击刷新重试。"))
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(AppTextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch suggestions.loadState {
        case .idle, .loading:
            L10n.string("study.scene.suggestions_loading", "正在获取推荐主题...")
        case .loaded:
            L10n.string("study.scene.suggestions_empty", "推荐主题暂未准备好，你可以先手动输入，或稍后点击刷新。")
        case .failed:
            L10n.string("study.scene.suggestions_failed", "暂时无法获取推荐，请点击刷新重试，也可以直接输入主题。")
        }
    }
}
