import SwiftUI

struct SentenceStudyBlankTokenView: View {
    let token: SentenceStudyToken
    let width: CGFloat
    let filledWord: SentenceStudyWordBankItem?
    let isFocused: Bool
    let isWrong: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if !token.prefix.isEmpty {
                Text(token.prefix)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTextColor.title)
            }

            Button(action: onTap) {
                Text(filledWord?.text ?? " ")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(filledWord == nil ? Color.clear : Color(red: 0.23, green: 0.62, blue: 0.36))
                    .frame(width: width, height: 32)
                    .background(blankBackground)
                    .overlay(blankOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            if !token.suffix.isEmpty {
                Text(token.suffix)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTextColor.title)
            }
        }
    }

    private var blankBackground: some ShapeStyle {
        if filledWord != nil {
            return AnyShapeStyle(
                Color(red: 0.84, green: 0.95, blue: 0.85)
            )
        }

        if isWrong {
            return AnyShapeStyle(Color(red: 0.98, green: 0.84, blue: 0.84))
        }

        if isFocused {
            return AnyShapeStyle(Color(red: 1.00, green: 0.94, blue: 0.86))
        }

        return AnyShapeStyle(Color(red: 0.98, green: 0.96, blue: 0.94))
    }

    private var blankOverlay: some View {
        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
            .stroke(
                filledWord != nil
                    ? Color.clear
                    : isFocused
                        ? Color(red: 0.95, green: 0.61, blue: 0.15)
                        : isWrong
                            ? Color(red: 0.90, green: 0.31, blue: 0.28)
                            : Color(red: 0.88, green: 0.82, blue: 0.75),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    dash: filledWord == nil ? [6, 4] : []
                )
            )
    }
}

struct SentenceStudyWordTagView: View {
    let word: String

    var body: some View {
        Text(word)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AppTextColor.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(AppSurfaceColor.card)
            )
            .overlay(
                Capsule()
                    .stroke(AppStroke.soft, lineWidth: 1.2)
            )
            .appSurfaceShadow()
    }
}

struct StudyFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let containerWidth = proposal.width ?? 320
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }

        return CGSize(width: containerWidth, height: currentY + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
