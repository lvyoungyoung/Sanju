import CoreGraphics
import SwiftUI

enum AppCornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let pill: CGFloat = 999
}

enum AppStroke {
    static let subtle = Color.black.opacity(0.06)
    static let soft = Color.black.opacity(0.10)
    static let highlight = Color.white.opacity(0.75)
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
    static let title = Color(red: 0.30, green: 0.28, blue: 0.30)
    static let primary = Color(red: 0.27, green: 0.27, blue: 0.28)
    static let secondary = Color.black.opacity(0.52)
    static let tertiary = Color.black.opacity(0.42)
    static let subtle = Color.black.opacity(0.30)
    static let inverse = Color.white
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
