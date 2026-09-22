import SwiftUI

/// Shared presentation only; callers retain their existing queue and completion rules.
struct StudyOverviewCard: View {
    let dueCount: Int
    let studiedCount: Int
    let buttonTitle: String
    let isPreparing: Bool
    let canStart: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
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
        .padding(24)
        .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: AppCornerRadius.large))
    }

    private func metric(_ count: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline)
            Text(count, format: .number)
                .font(AppTypography.pageTitle)
                .monospacedDigit()
        }
        .foregroundStyle(AppPalette.onAccent)
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
