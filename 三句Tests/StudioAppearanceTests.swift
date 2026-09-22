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
            (AppPalette.accentText, AppSurfaceColor.page),
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
            // ScrollView and the segmented picker need a UIKit host to render;
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
