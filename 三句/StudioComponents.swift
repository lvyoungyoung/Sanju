import SwiftUI

/// Shared presentation only; callers retain their existing queue and completion rules.
struct StudyOverviewCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let dueCount: Int
    let studiedCount: Int
    let buttonTitle: String
    let isPreparing: Bool
    let canStart: Bool
    var isCompact = false
    let onStart: () -> Void

    var body: some View {
        if isCompact {
            compactLayout
            .padding(AppSpacing.large)
            .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            .appCardShadow()
        } else {
            regularCard
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedCompactLayout
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.large) {
                    compactMetrics
                    compactStartButton
                }
                stackedCompactLayout
            }
        }
    }

    private var stackedCompactLayout: some View {
        VStack(spacing: AppSpacing.large) {
            compactMetrics
            compactStartButton
        }
    }

    private var compactMetrics: some View {
        HStack(spacing: AppSpacing.medium) {
            metric(dueCount, label: L10n.string("study.metric.due_today", "今日待学"))
            Rectangle().fill(AppStroke.subtle).frame(width: 1, height: 32)
            metric(studiedCount, label: L10n.string("study.metric.studied_today", "今日已学"))
        }
    }

    private var compactStartButton: some View {
        Button(action: onStart) {
            ZStack {
                Text(isPreparing ? L10n.string("study.button.start", "开始学习") : buttonTitle)
                    .font(.system(.subheadline, weight: .semibold))
                    .opacity(isPreparing ? 0 : 1)
                if isPreparing {
                    ProgressView().tint(AppPalette.onAccent)
                }
            }
            .foregroundStyle(AppPalette.onAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(AppPalette.accent.opacity(canStart || isPreparing ? 1 : 0.5), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(StudioPressStyle())
        .disabled(!canStart || isPreparing)
        .accessibilityLabel(buttonTitle)
    }

    private var regularCard: some View {
        VStack(spacing: AppSpacing.section) {
            HStack(alignment: .center, spacing: 24) {
                metric(dueCount, label: L10n.string("study.metric.due_today", "今日待学"))
                Rectangle().fill(AppPalette.onAccent.opacity(0.12)).frame(width: 1, height: 40)
                metric(studiedCount, label: L10n.string("study.metric.studied_today", "今日已学"))
            }

            Button(action: onStart) {
                HStack(spacing: 12) {
                    Text(buttonTitle)
                        .font(.system(.body, weight: .semibold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if isPreparing {
                        ProgressView().tint(AppHeroTextColor.title)
                    } else {
                        Image(systemName: "arrow.right").font(.body)
                    }
                }
                .foregroundStyle(AppHeroTextColor.title)
                .padding(.horizontal, 18)
                .frame(minHeight: 54)
                .background(.white.opacity(canStart ? 1 : 0.65), in: RoundedRectangle(cornerRadius: 19))
            }
            .buttonStyle(StudioPressStyle())
            .disabled(!canStart || isPreparing)
        }
        .padding(AppSpacing.section)
        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
    }

    private func metric(_ count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? AppSpacing.xSmall : AppSpacing.small) {
            Text(count, format: .number)
                .font(isCompact ? .system(.title2, weight: .bold) : AppTypography.pageTitle)
                .monospacedDigit()
            Text(label).font(isCompact ? .caption : .subheadline)
                .fixedSize(horizontal: isCompact && !dynamicTypeSize.isAccessibilitySize, vertical: true)
        }
        .foregroundStyle(isCompact ? AppTextColor.primary : AppPalette.onAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct StudioPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}

struct SentenceGroupPicker: View {
    @Binding var selection: SentencePresentationGroup

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SentencePresentationGroup.allCases, id: \.self) { group in
                Button {
                    selection = group
                } label: {
                    Text(group.localizedTabTitle)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(selection == group ? AppPalette.accentText : AppTextColor.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == group ? AppSurfaceColor.card : .clear, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == group ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppSurfaceColor.subtleFill, in: RoundedRectangle(cornerRadius: 19))
    }
}
