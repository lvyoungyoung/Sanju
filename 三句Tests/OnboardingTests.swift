import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class OnboardingTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "OnboardingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testFreshInstallShowsIntroductionAndResumesAfterInterruption() {
        withDefaults { defaults in
            XCTAssertTrue(OnboardingProgress.beginIfNeeded(defaults: defaults))
            defaults.set(true, forKey: AppStorageKey.installMarker)
            XCTAssertTrue(OnboardingProgress.beginIfNeeded(defaults: defaults))
        }
    }

    func testCompletionOrSkipPreventsAnotherAutomaticIntroduction() {
        withDefaults { defaults in
            XCTAssertTrue(OnboardingProgress.beginIfNeeded(defaults: defaults))
            OnboardingProgress.complete(defaults: defaults)
            XCTAssertFalse(OnboardingProgress.beginIfNeeded(defaults: defaults))
            XCTAssertFalse(defaults.bool(forKey: OnboardingProgress.startedKey))
        }
    }

    func testExistingInstallIsNotBlockedByIntroduction() {
        withDefaults { defaults in
            defaults.set(true, forKey: AppStorageKey.installMarker)
            XCTAssertFalse(OnboardingProgress.beginIfNeeded(defaults: defaults))
        }
    }

    func testExactlyThreePages() {
        XCTAssertEqual(OnboardingPage.allCases.count, 3)
        XCTAssertEqual(OnboardingPage.allCases.last, .flip)
        XCTAssertNil(OnboardingPage(rawValue: OnboardingPage.flip.rawValue + 1))
    }

    func testStoryPhotoIsBundledForOfflineIntroduction() {
        XCTAssertNotNil(UIImage(named: "OnboardingCafe"))
        for asset in Set(OnboardingAlbumArtwork.thumbnails) {
            XCTAssertNotNil(UIImage(named: asset), "Missing album thumbnail: \(asset)")
        }
    }

    func testFlippingUsesThreeMatchingPhotosAndReturnsToTheFirstExpression() {
        var demo = OnboardingFlipDemo()
        XCTAssertEqual(OnboardingFlipDemo.cards.count, 3)
        XCTAssertEqual(Set(OnboardingFlipDemo.cards.map(\.image)).count, 3)
        XCTAssertEqual(Set(OnboardingFlipDemo.cards.map(\.sentence)).count, 3)
        XCTAssertEqual(OnboardingFlipDemo.cards[0].sentence, OnboardingExpressionDemo.sentences[2])
        for index in OnboardingFlipDemo.cards.indices {
            XCTAssertEqual(demo.index, index)
            XCTAssertNotNil(UIImage(named: OnboardingFlipDemo.cards[index].image))
            let nextIndex = demo.nextIndex
            demo.phase = .swiping
            demo.advance()
            XCTAssertEqual(demo.index, nextIndex)
            XCTAssertEqual(demo.phase, .repeated)
        }
        XCTAssertEqual(demo.index, 0)
        XCTAssertTrue(OnboardingFlipPhase.listening.isListening)
        XCTAssertTrue(OnboardingFlipPhase.repeated.isListening)
        XCTAssertFalse(OnboardingFlipPhase.swiping.isListening)
        XCTAssertFalse(OnboardingFlipPhase.familiar.isListening)
    }

    func testFlipFramesRenderInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for phase in OnboardingFlipPhase.allCases {
                var demo = OnboardingFlipDemo()
                demo.phase = phase
                try capture(
                    OnboardingFlipArtwork(demo: demo).frame(height: 300).padding(24),
                    scheme: scheme, name: "Flip-\(phase)-\(scheme)"
                )
            }
        }
    }

    func testFlipCopyExplainsListeningAndPersonalRepetitionInBothLanguages() throws {
        for (language, titleWords, bodyWords) in [
            ("zh-Hans", ["翻相册", "听地道表达"], ["反复听", "自己生活"]),
            ("en", ["your photos", "natural expressions"], ["your own life", "again and again"])
        ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let title = bundle.localizedString(forKey: "onboarding.flip.title", value: nil, table: nil)
            let body = bundle.localizedString(forKey: "onboarding.flip.body", value: nil, table: nil)
            for word in titleWords { XCTAssertTrue(title.contains(word)) }
            for word in bodyWords { XCTAssertTrue(body.contains(word)) }
        }
    }

    func testFlipAnimationFinishes() throws {
        try capture(
            OnboardingView(initialPage: .flip, onFinish: {}).environment(\.scenePhase, .active),
            scheme: .light, name: "Flip-animation-finished", delay: 8,
            size: CGSize(width: 393, height: 852)
        )
    }

    func testFlipAnimationHandoffFrames() throws {
        for delay in [1.8, 3.85] {
            try capture(
                OnboardingView(initialPage: .flip, onFinish: {}).environment(\.scenePhase, .active),
                scheme: .light, name: "Flip-handoff-\(delay)", delay: delay,
                size: CGSize(width: 393, height: 852)
            )
        }
    }

    func testFlipNextPhotosRenderInBothThemes() throws {
        var demo = OnboardingFlipDemo()
        for index in OnboardingFlipDemo.cards.indices {
            for scheme in [ColorScheme.light, .dark] {
                try capture(OnboardingFlipArtwork(demo: demo).frame(height: 300).padding(24),
                            scheme: scheme, name: "Flip-photo-\(index)-\(scheme)")
            }
            demo.advance()
        }
    }

    func testAllPagesRenderInBothThemesOnSmallScreen() throws {
        for scheme in [ColorScheme.light, .dark] {
            for page in OnboardingPage.allCases {
                try capture(
                    OnboardingView(initialPage: page, onFinish: {}),
                    scheme: scheme,
                    name: "Onboarding-\(page.rawValue)-\(scheme)"
                )
            }
        }
    }

    func testAlbumFramesRenderInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            for phase in OnboardingAlbumPhase.allCases {
                try capture(
                    OnboardingAlbumArtwork(phase: phase).frame(height: 230).padding(24),
                    scheme: scheme,
                    name: "Album-\(phase)-\(scheme)"
                )
            }
        }
    }

    func testAlbumAnimationFinishes() throws {
        try capture(
            OnboardingView(onFinish: {}).environment(\.scenePhase, .active),
            scheme: .light,
            name: "Album-animation-finished",
            delay: 3.2
        )
    }

    func testExpressionDemoDoesNotOverrideUserSelection() {
        var demo = OnboardingExpressionDemo()
        demo.toggleFavorite(at: 0)
        XCTAssertNil(demo.selectedIndex)
        demo.visibleCount = 3
        demo.toggleFavorite(at: 0)
        demo.demonstrateFavorite()
        XCTAssertEqual(demo.selectedIndex, 0)
        demo.toggleFavorite(at: 0)
        demo.demonstrateFavorite()
        XCTAssertNil(demo.selectedIndex)
    }

    func testExpressionDemoFavoritesOnlyAfterReveal() {
        var demo = OnboardingExpressionDemo()
        demo.demonstrateFavorite()
        XCTAssertNil(demo.selectedIndex)
        demo.visibleCount = 3
        demo.demonstrateFavorite()
        XCTAssertEqual(demo.selectedIndex, 2)
        XCTAssertEqual(OnboardingExpressionDemo.sentences[2], "I could sit here all afternoon and do nothing.")
    }

    func testExpressionAnimationFinishesInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            try capture(
                OnboardingView(initialPage: .expression, onFinish: {})
                    .environment(\.scenePhase, .active),
                scheme: scheme,
                name: "Expression-finished-\(scheme)",
                delay: 4.2,
                size: CGSize(width: 393, height: 852)
            )
        }
    }

    private func capture(_ content: some View, scheme: ColorScheme, name: String, delay: TimeInterval = 0.2,
                         size: CGSize = CGSize(width: 320, height: 740)) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        defer { previousKeyWindow?.makeKeyAndVisible() }
        let host = UIHostingController(rootView: content
            .environment(\.colorScheme, scheme))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(delay))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        XCTAssertEqual(image.size.width, size.width, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(image.pngData()).count, 6_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
