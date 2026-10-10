import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class StudioAppearanceTests: XCTestCase {
    func testTextContrastInBothAppearances() {
        let pairs: [(Color, Color)] = [
            (AppTextColor.primary, AppSurfaceColor.page),
            (AppTextColor.primary, AppSurfaceColor.card),
            (AppTextColor.secondary, AppPalette.apricot),
            (AppTextColor.tertiary, AppSurfaceColor.card),
            (AppTextColor.primary, ProfileCardStyle.surface),
            (AppTextColor.secondary, ProfileCardStyle.surface),
            (AppTextColor.tertiary, ProfileCardStyle.surface),
            (AppTextColor.secondary, ProfileCardStyle.page),
            (AppPalette.accentText, AppSurfaceColor.page),
            (AppPalette.accentText, AppPalette.apricot),
            (AppPalette.accentText, AppSurfaceColor.card),
            (AppTextColor.primary, AppSurfaceColor.segmentedTrack),
            (AppTextColor.secondary, AppSurfaceColor.elevated),
            (AppPalette.onAccent, AppPalette.accent),
            (AppHeroTextColor.title, AppPalette.profile)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            traits.performAsCurrent {
                for (foreground, background) in pairs {
                    let a = luminance(UIColor(foreground).resolvedColor(with: traits))
                    let b = luminance(UIColor(background).resolvedColor(with: traits))
                    XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5)
                }
            }
        }
    }

    func testSharedPageBackgroundUsesWarmGrayAndKeepsDarkModeIndependent() {
        for (style, hex) in [(UIUserInterfaceStyle.light, UInt32(0xF3F1EC)), (.dark, 0x191B18)] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            traits.performAsCurrent {
                let page = UIColor(AppSurfaceColor.page).resolvedColor(with: traits)
                let profilePage = UIColor(ProfileCardStyle.page).resolvedColor(with: traits)
                XCTAssertEqual(page.cgColor, profilePage.cgColor)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(page.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                XCTAssertEqual(red, CGFloat((hex >> 16) & 0xff) / 255, accuracy: 0.001)
                XCTAssertEqual(green, CGFloat((hex >> 8) & 0xff) / 255, accuracy: 0.001)
                XCTAssertEqual(blue, CGFloat(hex & 0xff) / 255, accuracy: 0.001)
                XCTAssertEqual(alpha, 1)
                if style == .light {
                    XCTAssertEqual(luminance(UIColor(AppSurfaceColor.card).resolvedColor(with: traits)), 1, accuracy: 0.001)
                }
            }
        }
    }

    func testBorderlessCardsRemainDistinctFromPage() {
        XCTAssertEqual(ProfileCardStyle.cornerRadius, AppCornerRadius.card)
        XCTAssertEqual(AppCornerRadius.card, 18)
        XCTAssertEqual(AppCornerRadius.cardImage + 7, AppCornerRadius.card)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            traits.performAsCurrent {
                let page = luminance(UIColor(AppSurfaceColor.page).resolvedColor(with: traits))
                for surface in [AppSurfaceColor.card, ProfileCardStyle.surface] {
                    let card = luminance(UIColor(surface).resolvedColor(with: traits))
                    XCTAssertGreaterThan(card, page)
                    XCTAssertGreaterThan((card + 0.05) / (page + 0.05), 1.1)
                }
            }
        }
    }

    func testOverviewRendersOnSmallScreensAndWithLargeText() throws {
        for width in [CGFloat(320), 393] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility1] {
                    let content = StudyOverviewCard(
                        dueCount: 120,
                        studiedCount: 24,
                        buttonTitle: "Start Learning",
                        isPreparing: false,
                        canStart: true,
                        onStart: {}
                    )
                    .padding(24)
                    .frame(width: width)
                    .background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                    let renderer = ImageRenderer(content: content)
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    XCTAssertLessThan(image.size.height, 600)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Overview-\(width)-\(scheme)-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testSentenceGroupPickerSurfacesRemainDistinctInBothThemes() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            traits.performAsCurrent {
                let track = luminance(UIColor(AppSurfaceColor.segmentedTrack).resolvedColor(with: traits))
                for background in [AppSurfaceColor.page, AppSurfaceColor.card] {
                    let surface = luminance(UIColor(background).resolvedColor(with: traits))
                    let contrast = (max(track, surface) + 0.05) / (min(track, surface) + 0.05)
                    XCTAssertGreaterThan(contrast, 1.15, "The tab track must not blend into the page or surrounding card")
                }
            }
        }
    }

    func testSentenceGroupPickerRendersBothSelectionsWithLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for group in SentencePresentationGroup.allCases {
                for size in [DynamicTypeSize.large, .accessibility1] {
                    let content = SentenceGroupPicker(selection: .constant(group))
                        .padding(20)
                        .frame(width: 320)
                        .background(AppSurfaceColor.page)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                    let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
                    XCTAssertEqual(image.size.width, 320, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(image.size.height, 92)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "SentenceGroupPicker-\(scheme)-\(group.rawValue)-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testSentenceSkeletonRemainsDistinctEvenUnderTheShimmerHighlight() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            traits.performAsCurrent {
                let fill = UIColor(AppSurfaceColor.skeleton).resolvedColor(with: traits)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(fill.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                let opacity = CGFloat(SentenceSkeletonSection.shimmerOpacity)
                let highlight = UIColor(red: red * (1 - opacity) + opacity, green: green * (1 - opacity) + opacity,
                                        blue: blue * (1 - opacity) + opacity, alpha: 1)
                for foreground in [fill, highlight] {
                    let skeleton = luminance(foreground)
                    for background in [AppSurfaceColor.page, AppSurfaceColor.card] {
                        let surface = luminance(UIColor(background).resolvedColor(with: traits))
                        XCTAssertGreaterThan((max(skeleton, surface) + 0.05) / (min(skeleton, surface) + 0.05), 1.15)
                    }
                }
            }
        }
    }

    func testSentenceSkeletonKeepsAllThreePlaceholdersInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = SentenceSkeletonSection()
                .padding(20)
                .frame(width: 320)
                .background(AppSurfaceColor.card)
                .environment(\.colorScheme, scheme)
            let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
            XCTAssertEqual(image.size.width, 320, accuracy: 1)
            XCTAssertEqual(image.size.height, 66 * 3 + AppSpacing.medium * 2 + 40, accuracy: 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = "SentenceSkeleton-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func testSpeechSettingsRenderOnCompactScreensInBothThemes() throws {
        let suite = "SpeechAppearance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            // ScrollView needs a UIKit host to render;
            // ImageRenderer alone can silently produce an empty background.
            let host = UIHostingController(rootView: NavigationStack {
                SpeechSettingsView(speech: speech).environment(\.colorScheme, scheme)
            })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 740)
            window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
            XCTAssertEqual(image.size.width, 320, accuracy: 1)
            XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 6_000)
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 16, "The snapshot must contain controls, not an empty background")
            let attachment = XCTAttachment(image: image)
            attachment.name = "SpeechSettings-320-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
