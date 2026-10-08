import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class SpeechButtonLayoutTests: XCTestCase {
    func testPlaybackLabelKeepsItsSizeWhileLoading() throws {
        let suite = "SpeechButtonLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        let text = "Every photo tells a story."
        for title in ["播放", "Play", "朗读句子", "Read aloud"] {
            let idle = try size(of: SpeechPlaybackLabel(speech: speech, text: text, title: title)
                .font(.system(size: 13, weight: .medium)))
            speech.speak(text)
            let loading = try size(of: SpeechPlaybackLabel(speech: speech, text: text, title: title)
                .font(.system(size: 13, weight: .medium)))
            speech.stop()
            XCTAssertEqual(idle.width, loading.width, accuracy: 0.1, title)
            XCTAssertEqual(idle.height, loading.height, accuracy: 0.1, title)
        }
    }

    func testSentencePlaybackButtonKeepsItsSizeWhileLoading() throws {
        let suite = "SpeechButtonLayout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        let text = "Every photo tells a story."
        let idle = try size(of: SentencePlaybackButton(speech: speech, text: text))
        speech.speak(text)
        let loading = try size(of: SentencePlaybackButton(speech: speech, text: text))
        speech.stop()
        XCTAssertEqual(idle.width, loading.width, accuracy: 0.1)
        XCTAssertEqual(idle.height, loading.height, accuracy: 0.1)
        let label = try size(of: SpeechPlaybackLabel(speech: speech, text: text,
                                                  title: L10n.string("new.result.play", "播放"),
                                                  playingTitle: L10n.string("new.result.playing", "播放中"))
            .font(.system(.subheadline, weight: .semibold)))
        XCTAssertEqual(idle.width, max(110, label.width + 44), accuracy: 1)
        XCTAssertGreaterThanOrEqual(idle.height, 44)
    }

    func testFavoriteButtonKeepsItsSizeOnToggle() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let idle = try size(of: SentenceFavoriteButton(isFavorite: false, action: {})
                .environment(\.dynamicTypeSize, typeSize))
            let saved = try size(of: SentenceFavoriteButton(isFavorite: true, action: {})
                .environment(\.dynamicTypeSize, typeSize))
            XCTAssertEqual(idle.width, saved.width, accuracy: 0.1)
            XCTAssertEqual(idle.height, saved.height, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(idle.height, 44)
        }
    }

    func testStyledPlaybackButtonsKeepTheirSizeInEveryState() throws {
        for (title, playingTitle) in [("播放", "播放中"), ("Play", "Playing")] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                var previous: CGSize?
                for state in [SpeechPlaybackState.idle, .loading, .playing] {
                    let renderedSize = try size(of: Button {} label: {
                        SpeechPlaybackContent(state: state, title: title, icon: "play.fill", playingTitle: playingTitle)
                    }
                    .buttonStyle(SentenceActionButtonStyle(isEmphasized: true))
                    .environment(\.dynamicTypeSize, typeSize))
                    if let previous {
                        XCTAssertEqual(renderedSize.width, previous.width, accuracy: 0.1)
                        XCTAssertEqual(renderedSize.height, previous.height, accuracy: 0.1)
                    }
                    XCTAssertGreaterThanOrEqual(renderedSize.height, 44)
                    previous = renderedSize
                }
            }
        }
    }

    func testSentenceActionsStackOnCompactScreensWithLargeText() throws {
        let suite = "SentenceActions.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        let actions = SentenceActions(speech: speech, text: "A quiet afternoon.", isFavorite: false, onFavorite: {})
        let regular = try size(of: actions.frame(width: 256))
        let large = try size(of: actions.environment(\.dynamicTypeSize, .accessibility3).frame(width: 256))
        XCTAssertEqual(regular.width, 256, accuracy: 0.1)
        XCTAssertEqual(large.width, 256, accuracy: 0.1)
        XCTAssertGreaterThan(large.height, regular.height + 44)
    }

    func testSentenceActionCardsInBothThemes() throws {
        for scheme in [ColorScheme.light, .dark] {
            let content = VStack(alignment: .leading, spacing: 16) {
                ForEach(Array([SpeechPlaybackState.idle, .loading, .playing].enumerated()), id: \.offset) { _, state in
                    VStack(alignment: .leading, spacing: 16) {
                        Text("The first sip of coffee makes this quiet morning even better.")
                            .font(AppTypography.sentence)
                            .foregroundStyle(AppTextColor.primary)
                        Text("第一口咖啡，让这个安静的早晨更美好了。")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTextColor.secondary)
                        HStack(spacing: 12) {
                            Button {} label: {
                                SpeechPlaybackContent(state: state, title: "播放", icon: "play.fill", playingTitle: "播放中")
                            }
                            .buttonStyle(SentenceActionButtonStyle(isEmphasized: true))
                            SentenceFavoriteButton(isFavorite: state == .playing, action: {})
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
                    .appCardBorder()
                }
            }
            .padding(20)
            .background(AppSurfaceColor.page)
            .environment(\.colorScheme, scheme)
            let host = UIHostingController(rootView: content)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 800)
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
            let attachment = XCTAttachment(image: image)
            attachment.name = "SentenceActions-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPlaybackLabelKeepsItsSizeInEveryState() throws {
        for (title, playingTitle) in [("播放", "播放中"), ("Play", "Playing"),
                                      ("朗读句子", "朗读中"), ("Read sentence", "Playing")] {
            for scheme in [ColorScheme.light, .dark] {
                var previous: CGSize?
                for state in [SpeechPlaybackState.idle, .loading, .playing] {
                    let renderedSize = try size(of: SpeechPlaybackContent(
                        state: state, title: title, icon: "speaker.wave.2.fill", playingTitle: playingTitle
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .environment(\.colorScheme, scheme))
                    if let previous {
                        XCTAssertEqual(renderedSize.width, previous.width, accuracy: 0.1)
                        XCTAssertEqual(renderedSize.height, previous.height, accuracy: 0.1)
                    }
                    previous = renderedSize
                }
            }
        }
    }

    func testStudyPlaybackStateFollowsCurrentSentenceOnly() {
        let text = "A quiet afternoon."
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: nil, loadingText: nil), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: text, loadingText: text), .loading)
        XCTAssertEqual(SpeechPlaybackState(text: "  \(text)\n", activeText: text, loadingText: nil), .playing)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: "Other sentence.", loadingText: nil), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: nil, loadingText: nil), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: "  ", activeText: nil, loadingText: nil), .idle)
    }

    private func size<V: View>(of view: V) throws -> CGSize {
        let renderer = ImageRenderer(content: view.fixedSize())
        return try XCTUnwrap(renderer.uiImage).size
    }
}
