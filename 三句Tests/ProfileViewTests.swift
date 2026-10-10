import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class ProfileViewTests: XCTestCase {
    func testIdentityHeaderHasADistinctCardAndKeepsTheGuestPurchaseWarning() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            var result: Result<Void, Error>?
            traits.performAsCurrent {
                result = Result { try verifyIdentityHeader(style: style) }
            }
            try XCTUnwrap(result).get()
        }
    }

    private func verifyIdentityHeader(style: UIUserInterfaceStyle) throws {
        let plain = try identityImage(profile: nil, warning: false, style: style)
        let warning = try identityImage(profile: nil, warning: true, style: style)
        XCTAssertGreaterThan(warning.size.height, plain.size.height)
        let cardPoint = CGPoint(x: plain.size.width / 2, y: 8)
        XCTAssertEqual(try pixel(plain, at: cardPoint),
                       try pixel(warning, at: cardPoint))
        let background = try XCTUnwrap(ImageRenderer(content:
            ProfileCardStyle.page.frame(width: 1, height: 1)
                .environment(\.colorScheme, style == .dark ? .dark : .light)
        ).uiImage)
        let surface = try XCTUnwrap(ImageRenderer(content:
            ProfileCardStyle.surface.frame(width: 1, height: 1)
                .environment(\.colorScheme, style == .dark ? .dark : .light)
        ).uiImage)
        XCTAssertEqual(try pixel(plain, at: cardPoint),
                       try pixel(surface, at: .zero), "The identity card must use the shared card surface")
        XCTAssertNotEqual(try pixel(plain, at: cardPoint),
                          try pixel(background, at: .zero), "The identity card must stand apart from the page")
        let profile = UserProfile(appleUserID: "test", nickname: "A Little Every Day", email: "hello@example.com")
        let signedIn = try identityImage(profile: profile, warning: false, style: style)
        let signedInWithPurchase = try identityImage(profile: profile, warning: true, style: style)
        XCTAssertEqual(signedIn.pngData(), signedInWithPurchase.pngData(),
                       "The purchase warning belongs only to the guest state")
        XCTAssertEqual(try pixel(signedIn, at: cardPoint), try pixel(surface, at: .zero))
        let avatar = try XCTUnwrap(ImageRenderer(content:
            Image("ProfileAvatar").resizable().scaledToFill().frame(width: 64, height: 64)
        ).uiImage)
        let avatarPoint = CGPoint(x: AppSpacing.xLarge + 32, y: AppSpacing.xLarge + 32)
        let expectedAvatarPixel = try pixel(avatar, at: CGPoint(x: 32, y: 32))
        for header in [plain, signedIn] {
            for (actual, expected) in zip(try pixel(header, at: avatarPoint), expectedAvatarPixel) {
                XCTAssertEqual(Double(actual), Double(expected), accuracy: 2,
                               "Both account states must use the original illustrated avatar")
            }
        }
        attach(warning, name: "Profile-GuestWarning-\(style.rawValue)")
        attach(signedIn, name: "Profile-Identity-\(style.rawValue)")
    }

    func testHeaderAndCreditCardFitSmallScreensAndLargeText() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility1] {
            let header = ProfileIdentityHeader(
                profile: UserProfile(appleUserID: "test", nickname: "A very long nickname for this small screen", email: "a.long.email.address@example.com"),
                hasPurchaseHistory: false, onEditNickname: {}, onSignIn: {}
            )
            let credit = ProfileCreditCard(credits: 100_000, isPurchaseDisabled: false, onPurchase: {})
            let view = VStack(spacing: 24) { header; credit }
                .padding(24).frame(width: 320)
                .background(ProfileCardStyle.page)
                .environment(\.dynamicTypeSize, typeSize)
            let image = try XCTUnwrap(ImageRenderer(content: view).uiImage)
            XCTAssertEqual(image.size.width, 320)
            XCTAssertLessThan(image.size.height, 500)
            attach(image, name: "Profile-Compact-\(typeSize)")
        }
    }

    func testSpeechRowUpdatesImmediatelyWhenTheSelectedVoiceChanges() async throws {
        let suite = "ProfileVoice.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        let host = try ProfileTestHost(view: NavigationStack {
            ProfileSpeechSettingsLink(speech: speech).profileCardSurface()
                .padding(24).background(ProfileCardStyle.page)
        })
        defer { host.close(); speech.stop() }
        try await host.settle()
        let before = host.snapshot()
        speech.applyVoice(speech.selectedVoice == .dean ? .mia : .dean)
        try await host.settle()
        XCTAssertNotEqual(before.pngData(), host.snapshot().pngData(),
                          "The row must observe speech preferences, not wait for another AppModel update")
    }

    func testReminderKeepsItsToggleCallbacksAndTimeControl() async throws {
        var saved = 0
        var disabled = 0
        for enabled in [false, true] {
            let row = LearningReminderSetupCard(
                reminderTime: .constant(Date(timeIntervalSince1970: 0)),
                isEnabled: enabled, isSaving: false, statusMessage: nil, statusIsError: false,
                onSave: { saved += 1 }, onDisable: { disabled += 1 }, onEditTime: {}
            )
            let host = try ProfileTestHost(view: row.profileCardSurface().padding(24).background(ProfileCardStyle.page))
            defer { host.close() }
            try await host.settle()
            let toggle = try XCTUnwrap(host.descendants.compactMap { $0 as? UISwitch }.first)
            XCTAssertEqual(toggle.isOn, enabled)
            toggle.setOn(!enabled, animated: false)
            toggle.sendActions(for: .valueChanged)
            attach(host.snapshot(), name: "Profile-Reminder-\(enabled)")
        }
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(disabled, 1)
    }

    func testGuestPageAndRestoreStateRenderInBothThemes() async throws {
        let model = AppModel()
        defer { model.speech.stop() }
        model.isNetworkAvailable = false
        model.supabaseSession = nil
        model.profile = nil
        model.processedPurchaseTransactionIDs = ["local-test-purchase"]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for restoring in [false, true] {
                model.isRestoringAuthenticatedSession = restoring
                let host = try ProfileTestHost(view: NavigationStack {
                    ProfileView().environmentObject(model)
                }, style: style)
                defer { host.close() }
                try await host.settle()
                attach(host.snapshot(), name: "Profile-Page-\(style.rawValue)-restoring-\(restoring)")
                if !restoring {
                    let scroll = try XCTUnwrap(host.descendants.compactMap { $0 as? UIScrollView }.first)
                    scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                    try await host.settle()
                    attach(host.snapshot(), name: "Profile-PageBottom-\(style.rawValue)")
                }
            }
        }
        model.isRestoringAuthenticatedSession = false
    }

    private func identityImage(profile: UserProfile?, warning: Bool, style: UIUserInterfaceStyle) throws -> UIImage {
        try XCTUnwrap(ImageRenderer(content: ProfileIdentityHeader(
            profile: profile, hasPurchaseHistory: warning, onEditNickname: {}, onSignIn: {}
        ).frame(width: 345).background(ProfileCardStyle.page)
            .environment(\.colorScheme, style == .dark ? .dark : .light)).uiImage)
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let result = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.translateBy(x: -point.x, y: -(CGFloat(cgImage.height) - point.y - 1))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        XCTAssertTrue(result)
        return bytes
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class ProfileTestHost {
    let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init<V: View>(view: V, style: UIUserInterfaceStyle = .light) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    var descendants: [UIView] {
        func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }
        return all(window)
    }

    func settle() async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
    }

    func snapshot() -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }
}
