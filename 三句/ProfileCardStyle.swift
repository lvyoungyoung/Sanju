import SwiftUI

enum ProfileCardStyle {
    static let cornerRadius = AppCornerRadius.card
    static let page = AppSurfaceColor.page
    static let surface = AppPalette.adaptive(0xFFFFFF, 0x292D26)
}

extension View {
    func profileCardSurface(_ color: Color = ProfileCardStyle.surface) -> some View {
        background(
            color,
            in: RoundedRectangle(cornerRadius: ProfileCardStyle.cornerRadius, style: .continuous)
        )
    }
}
