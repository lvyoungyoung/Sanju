import CoreGraphics
import SwiftUI

enum AppCornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let pill: CGFloat = 999
}

enum AppStroke {
    static let subtle = Color(.separator).opacity(0.32)
    static let soft = Color(.separator).opacity(0.48)
    static let highlight = Color(.separator).opacity(0.22)
}

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
    static let section: CGFloat = 24
    static let xxLarge: CGFloat = 28
    static let xxxLarge: CGFloat = 32
}

enum AppControlHeight {
    static let compact: CGFloat = 40
    static let regular: CGFloat = 48
    static let prominent: CGFloat = 52
}

enum AppControlPadding {
    static let compact: CGFloat = 12
    static let regular: CGFloat = 16
    static let prominent: CGFloat = 18
}

enum AppIconSize {
    static let compact: CGFloat = 13
    static let regular: CGFloat = 15
    static let prominent: CGFloat = 16
}

enum AppFontSize {
    static let badge: CGFloat = 11
    static let caption: CGFloat = 12
    static let metadata: CGFloat = 13
    static let sectionLabel: CGFloat = 14
    static let body: CGFloat = 15
    static let bodyProminent: CGFloat = 16
    static let field: CGFloat = 17
    static let cardTitle: CGFloat = 18
    static let stat: CGFloat = 20
    static let panelTitle: CGFloat = 22
    static let heroStat: CGFloat = 24
    static let pageTitle: CGFloat = 28
    static let display: CGFloat = 34
    static let celebration: CGFloat = 42
}

enum AppTextColor {
    static let title = Color(.label)
    static let primary = Color(.label)
    static let secondary = Color(.secondaryLabel)
    static let tertiary = Color(.tertiaryLabel)
    static let subtle = Color(.quaternaryLabel)
    static let inverse = Color(.systemBackground)
}

enum AppHeroTextColor {
    static let title = Color(red: 0.24, green: 0.24, blue: 0.23)
    static let secondary = Color(red: 0.44, green: 0.40, blue: 0.34)
    static let tertiary = Color(red: 0.58, green: 0.53, blue: 0.46)
}

enum AppSurfaceColor {
    static let page = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
    static let elevated = Color(.tertiarySystemGroupedBackground)
    static let input = Color(.systemBackground)
    static let subtleFill = Color(.systemFill)
    static let secondaryFill = Color(.secondarySystemFill)
}

enum AppImageAspectRatio {
    static let defaultDisplay: CGFloat = 3.0 / 4.0
    static let minDisplay: CGFloat = 9.0 / 21.0
    static let maxDisplay: CGFloat = 21.0 / 9.0

    static func clamped(size: CGSize) -> CGFloat {
        clamped(width: size.width, height: size.height)
    }

    static func clamped(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else {
            return defaultDisplay
        }

        return min(max(width / height, minDisplay), maxDisplay)
    }
}

extension View {
    func appSurfaceShadow() -> some View {
        shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 6)
    }

    func appCardShadow() -> some View {
        shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 10)
    }

    func appHeroShadow() -> some View {
        shadow(color: Color.black.opacity(0.03), radius: 18, x: 0, y: 12)
    }

    func appAccentShadow(_ color: Color, opacity: Double = 0.16) -> some View {
        shadow(color: color.opacity(opacity), radius: 12, x: 0, y: 6)
    }
}
