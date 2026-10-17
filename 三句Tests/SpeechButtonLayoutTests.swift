import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class SpeechButtonLayoutTests: XCTestCase {
    func testScenarioTabsDisplayOneThreeTurnConversationInsteadOfEveryGroup() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        defer { model.speech.stop() }
        for count in [2, 3] {
            let titles = ["喝点什么", "忙里偷闲", "靠窗坐吧"]
            let memory = MemoryEntry(imageData: Data(), sentences: (0..<(count * 3)).map { index in
                SentenceRecord(english: ["Would you like something warm to drink?", "A coffee sounds good after that long walk.", "Let's find a quiet table by the window."][index % 3],
                    chinese: ["你想喝点热的吗？", "走了这么久，喝杯咖啡不错。", "我们找个靠窗的安静位置吧。"][index % 3],
                    presentationGroup: .whatIDSay,
                    dialogue: SentenceDialogue(index: index / 3, turn: index % 3, title: titles[index / 3]))
            })
            XCTAssertTrue(memory.sentences.isCompleteScenarioDialogues)
            let panel = MemoryDetailSentencePanel(memory: memory).environmentObject(model).frame(width: 345)
            let allGroups = VStack {
                ForEach(memory.sentences.dialogueGroups) { group in
                    MemoryDialogueGroupCard(group: group, context: memory.context)
                }
            }.environmentObject(model).frame(width: 345)
            XCTAssertLessThan(try size(of: panel).height, try size(of: allGroups).height)
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: panel.padding(20).background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme).fixedSize(horizontal: false, vertical: true))
                let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                attachment.name = "ScenarioTabs-\(count)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testChatBubbleFavoriteStateDoesNotShiftLayout() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        defer { model.speech.stop() }
        for turn in [0, 1] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let sentence = SentenceRecord(english: "Let's sit by the window and enjoy the afternoon light.",
                    chinese: "我们坐在窗边，享受午后的阳光吧。", dialogue: SentenceDialogue(index: 0, turn: turn))
                var saved = sentence
                saved.isFavorite = true
                let plainSize = try size(of: MemoryDialogueChatBubbleContent(sentence: sentence, context: .legacyEnglish, isExpanded: .constant(true))
                    .environmentObject(model).environment(\.dynamicTypeSize, typeSize).frame(width: 280))
                let savedSize = try size(of: MemoryDialogueChatBubbleContent(sentence: saved, context: .legacyEnglish, isExpanded: .constant(true))
                    .environmentObject(model).environment(\.dynamicTypeSize, typeSize).frame(width: 280))
                XCTAssertEqual(plainSize.width, 280, accuracy: 1)
                XCTAssertEqual(plainSize, savedSize)
            }
        }
    }

    func testChatBubbleStartsCollapsedAndDetailsExpandWithoutChangingWidth() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        defer { model.speech.stop() }
        for turn in [0, 1] {
            let sentence = SentenceRecord(english: "Let's sit by the window and enjoy the afternoon light.",
                chinese: "我们坐在窗边，享受午后的阳光吧。", dialogue: SentenceDialogue(index: 0, turn: turn))
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let initial = try size(of: MemoryDialogueChatBubble(sentence: sentence, context: .legacyEnglish)
                    .environmentObject(model).environment(\.dynamicTypeSize, typeSize).frame(width: 280))
                let collapsed = try size(of: MemoryDialogueChatBubbleContent(sentence: sentence, context: .legacyEnglish, isExpanded: .constant(false))
                    .environmentObject(model).environment(\.dynamicTypeSize, typeSize).frame(width: 280))
                let expanded = MemoryDialogueChatBubbleContent(sentence: sentence, context: .legacyEnglish, isExpanded: .constant(true))
                    .environmentObject(model).environment(\.dynamicTypeSize, typeSize).frame(width: 280)
                let expandedSize = try size(of: expanded)
                XCTAssertEqual(initial, collapsed)
                XCTAssertEqual(expandedSize.width, collapsed.width, accuracy: 1)
                XCTAssertGreaterThan(expandedSize.height, collapsed.height + 44)
                let renderer = ImageRenderer(content: expanded.padding(20).background(AppSurfaceColor.page)
                    .fixedSize(horizontal: false, vertical: true))
                let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                attachment.name = "ExpandedDialogue-\(turn)-\(typeSize)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testResultPanelDisplaysAllThreePairsWithoutCategoryTabs() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        defer { model.speech.stop() }
        let memory = MemoryEntry(imageData: Data(), sentences: (0..<6).map { index in
            SentenceRecord(english: index % 2 == 0 ? "Shall we sit by the window for a while?" : "Yes, the afternoon light is really lovely over there.",
                chinese: index % 2 == 0 ? "我们在窗边坐一会儿好吗？" : "好啊，那边的午后阳光真的很舒服。",
                presentationGroup: index < 2 ? .whatISee : .whatIDSay,
                dialogue: SentenceDialogue(index: index / 2, turn: index % 2))
        })
        let panel = MemoryDetailSentencePanel(memory: memory).environmentObject(model).frame(width: 345)
        let cardsOnly = VStack(spacing: 10) {
            ForEach(memory.sentences.dialogueGroups) { group in
                MemoryDialogueGroupCard(group: group, context: memory.context)
            }
        }.environmentObject(model).frame(width: 345)
        XCTAssertEqual(memory.sentences.dialogueGroups.count, 3)
        // Numbered separators and additional inter-group space distinguish three conversations.
        XCTAssertGreaterThan(try size(of: panel).height, try size(of: cardsOnly).height + 90)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: panel.padding(20).background(AppSurfaceColor.page)
                .environment(\.colorScheme, scheme).fixedSize(horizontal: false, vertical: true))
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "ThreeDialoguePairs-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testDialogueResultCardsUseLessVerticalSpaceWithoutShrinkingTextOrButtons() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        defer { model.speech.stop() }
        let turns = [
            SentenceRecord(english: "This looks like a lovely place to take a break.", chinese: "这里看起来很适合休息一下。", dialogue: SentenceDialogue(index: 0, turn: 0)),
            SentenceRecord(english: "Let's grab a coffee and sit by the window.", chinese: "我们买杯咖啡，坐在窗边吧。", dialogue: SentenceDialogue(index: 0, turn: 1))
        ]
        for width in [CGFloat(280), 345] {
            let compact = MemoryDialogueGroupCard(group: SentenceDialogueGroup(sentences: turns), context: .legacyEnglish)
                .environmentObject(model).frame(width: width)
            let previous = VStack(alignment: .leading, spacing: 16) {
                MemoryDetailSentenceRow(sentence: turns[0])
                Divider()
                MemoryDetailSentenceRow(sentence: turns[1])
            }.padding(20).environmentObject(model).frame(width: width)
            let compactSize = try size(of: compact)
            let previousSize = try size(of: previous)
            XCTAssertEqual(compactSize.width, width, accuracy: 1)
            // Chat bubbles trade some line width for distinct left/right speakers.
            XCTAssertLessThan(compactSize.height, previousSize.height)
            for scheme in [ColorScheme.light, .dark] {
                for typeSize in [DynamicTypeSize.large, .accessibility3] {
                    let renderer = ImageRenderer(content: compact
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, typeSize)
                        .fixedSize(horizontal: false, vertical: true))
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "CompactDialogue-\(Int(width))-\(scheme)-\(typeSize)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

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
