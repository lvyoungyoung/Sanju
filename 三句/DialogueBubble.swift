import SwiftUI

struct DialogueBubble<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let isReply: Bool
    var incomingFill: Color = AppSurfaceColor.card
    var bottomPadding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !isReply && !typeSize.isAccessibilitySize { speaker }
            VStack(alignment: .leading, spacing: 6) {
                if typeSize.isAccessibilitySize { speaker }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, bottomPadding)
            .background(isReply ? AppPalette.apricot : incomingFill,
                in: UnevenRoundedRectangle(topLeadingRadius: isReply ? 18 : 5,
                    bottomLeadingRadius: 18, bottomTrailingRadius: 18,
                    topTrailingRadius: isReply ? 5 : 18, style: .continuous))
            if isReply && !typeSize.isAccessibilitySize { speaker }
        }
        .padding(isReply ? .leading : .trailing, typeSize.isAccessibilitySize ? 12 : 56)
        .accessibilityElement(children: .contain)
    }

    private var speaker: some View {
        SentenceSpeakerBadge(speaker: isReply ? "B" : "A")
            .padding(.top, 4)
    }
}
