import SwiftUI

struct StudyTopicMasteryCard: View {
    let score: Int

    var clampedScore: Int { min(max(score, 0), 100) }

    private var fraction: Double { Double(clampedScore) / 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.medium) {
                Text(L10n.string("study.topic.mastery.title", "掌握程度"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.title2, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(AppPalette.accentText)
                    .fixedSize()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppSurfaceColor.subtleFill)
                    Capsule()
                        .fill(AppPalette.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
        .padding(AppSpacing.large)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .appCardBorder()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("study.topic.mastery.title", "掌握程度"))
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}
