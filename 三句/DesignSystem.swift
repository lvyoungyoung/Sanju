import CoreGraphics
import SwiftUI
import UIKit

enum AppPalette {
    static let accent = Color(red: 0.945, green: 0.420, blue: 0.231)
    static let accentText = adaptive(0x9F3715, 0xFFB695)
    static let apricot = adaptive(0xFFF0E2, 0x35291F)
    static let profile = Color(red: 0.918, green: 0.945, blue: 0.961)
    static let onAccent = Color(red: 0.20, green: 0.13, blue: 0.09)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

enum AppTypography {
    static let pageTitle = Font.custom("AvenirNext-Bold", size: 34, relativeTo: .largeTitle)
    static let sentence = Font.custom("AvenirNext-DemiBold", size: 18, relativeTo: .body)
}

enum AppCornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 19
    static let large: CGFloat = 28
    static let photo: CGFloat = 25
    static let pill: CGFloat = 999
}

enum AppStroke {
    static let subtle = AppPalette.adaptive(0xE9E9E1, 0x3B3C36)
    static let soft = AppPalette.adaptive(0xDDDED5, 0x4D4E47)
    static let highlight = subtle
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
    static let prominent: CGFloat = 56
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
    static let title = AppPalette.adaptive(0x282A25, 0xF3F2EB)
    static let primary = title
    static let secondary = AppPalette.adaptive(0x686B62, 0xB8BAB0)
    static let tertiary = AppPalette.adaptive(0x71746A, 0xA9ACA0)
    static let subtle = tertiary
    static let inverse = Color(.systemBackground)
}

enum AppHeroTextColor {
    static let title = Color(red: 0.24, green: 0.24, blue: 0.23)
    static let secondary = Color(red: 0.44, green: 0.40, blue: 0.34)
    static let tertiary = Color(red: 0.58, green: 0.53, blue: 0.46)
}

enum AppSurfaceColor {
    static let page = AppPalette.adaptive(0xFCFBF8, 0x191B18)
    static let card = AppPalette.adaptive(0xFFFFFF, 0x242721)
    static let elevated = AppPalette.adaptive(0xF3F3EE, 0x30342C)
    static let input = card
    static let subtleFill = AppPalette.adaptive(0xF0F1EB, 0x34382F)
    static let secondaryFill = subtleFill
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
        shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
    }

    func appCardBorder(cornerRadius: CGFloat = AppCornerRadius.large) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppStroke.subtle, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    func appHeroShadow() -> some View {
        shadow(color: Color.black.opacity(0.015), radius: 4, x: 0, y: 2)
    }

    func appAccentShadow(_ color: Color, opacity: Double = 0.16) -> some View {
        shadow(color: color.opacity(opacity), radius: 12, x: 0, y: 6)
    }
}
