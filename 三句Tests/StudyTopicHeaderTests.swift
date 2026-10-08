import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class StudyTopicHeaderTests: XCTestCase {
    func testMasteryIsBoundedWithoutChangingValidScores() {
        for (score, expected) in [(-1, 0), (0, 0), (62, 62), (100, 100), (120, 100)] {
            XCTAssertEqual(StudyTopicMasteryCard(score: score).clampedScore, expected)
        }
    }

    func testCompactOverviewIsShorterThanTheExistingHomeCard() throws {
        let regular = ImageRenderer(content: overview(compact: false).frame(width: 320))
        let compact = ImageRenderer(content: overview(compact: true).frame(width: 320))
        let regularImage = try XCTUnwrap(regular.uiImage)
        let compactImage = try XCTUnwrap(compact.uiImage)
        XCTAssertGreaterThan(regularImage.size.height - compactImage.size.height, 30)
    }

    func testDetailCardsRenderOnSmallScreensAndWithLargeText() throws {
        for width in [CGFloat(320), 393] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility1] {
                    let content = VStack(spacing: AppSpacing.large) {
                        StudyTopicMasteryCard(score: 62)
                        overview(compact: true)
                    }
                    .padding(AppSpacing.section)
                    .frame(width: width)
                    .background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                    let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    XCTAssertLessThan(image.size.height, 600)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "TopicHeader-\(width)-\(scheme)-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testMasteryRemainsACompactStandaloneCard() throws {
        let image = try XCTUnwrap(ImageRenderer(
            content: StudyTopicMasteryCard(score: 62).frame(width: 345)
        ).uiImage)
        XCTAssertLessThan(image.size.height, 130)
    }

    func testMasteryRendersAtBothEndsAndWhilePreparing() throws {
        for score in [0, 100] {
            for isPreparing in [false, true] {
                let content = VStack(spacing: AppSpacing.large) {
                    StudyTopicMasteryCard(score: score)
                    overview(compact: true, isPreparing: isPreparing)
                }
                .frame(width: 272)
                let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
                XCTAssertEqual(image.size.width, 272, accuracy: 1)
                XCTAssertLessThan(image.size.height, 300)
            }
        }
    }

    private func overview(compact: Bool, isPreparing: Bool = false) -> some View {
        StudyOverviewCard(
            dueCount: 8,
            studiedCount: 3,
            buttonTitle: isPreparing
                ? L10n.string("study.button.preparing", "正在准备学习内容...")
                : L10n.string("study.button.start", "开始学习"),
            isPreparing: isPreparing,
            canStart: true,
            isCompact: compact,
            onStart: {}
        )
    }
}
