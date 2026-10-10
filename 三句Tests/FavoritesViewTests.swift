import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class FavoritesViewTests: XCTestCase {
    func testListContainsOnlyFavoritesFromBothSentenceGroupsNewestFirst() {
        let older = MemoryEntry(createdAt: Date(timeIntervalSince1970: 1), imageData: Data(), sentences: [
            SentenceRecord(english: "Old favorite", chinese: "旧收藏", isFavorite: true),
            SentenceRecord(english: "Not saved", chinese: "未收藏")
        ])
        let newer = MemoryEntry(createdAt: Date(timeIntervalSince1970: 2), imageData: Data(), sentences: [
            SentenceRecord(english: "A coffee cup sits here.", chinese: "咖啡杯在这里。", isFavorite: true),
            SentenceRecord(english: "I really needed this break.", chinese: "我真的需要休息一下。", presentationGroup: .whatIDSay, isFavorite: true)
        ])
        let id = newer.sentences[1].id
        let items = FavoriteSentenceListItem.makeItems(memories: [older, newer], studyCounts: [id: 3])
        XCTAssertEqual(items.map(\.id), [newer.sentences[0].id, id, older.sentences[0].id])
        XCTAssertEqual(items.map(\.studyCount), [0, 3, 0])
        XCTAssertEqual(items.first?.favorite.memoryID, newer.id)
    }

    func testFavoritesStudyAndSameDayReviewKeepExistingProgressRules() async throws {
        let model = makeModel()
        let favorite = model.memories[0].sentences[0]
        await model.refreshSentenceStudyDueCount()
        XCTAssertEqual(model.sentenceStudyDueCount, 1)
        XCTAssertEqual(model.sentenceStudyTodayCount, 0)
        await model.startSentenceStudy()
        XCTAssertTrue(model.isShowingSentenceStudySession)
        XCTAssertEqual(model.sentenceStudyQueue.map(\.sentenceID), [favorite.id])
        XCTAssertFalse(model.isRepeatingSentenceStudyQueue)

        let progress = try await model.recordSentenceStudyCompletion(sentenceID: favorite.id)
        await model.refreshSentenceStudyDueCount()
        XCTAssertEqual(progress.correctCount, 1)
        XCTAssertEqual(model.favoriteSentenceStudyCounts[favorite.id], 1)
        XCTAssertEqual(model.sentenceStudyDueCount, 0)
        XCTAssertEqual(model.sentenceStudyTodayCount, 1)
        model.isShowingSentenceStudySession = false
        await model.startSentenceStudy()
        XCTAssertTrue(model.isRepeatingSentenceStudyQueue)
        XCTAssertEqual(model.sentenceStudyQueue.map(\.sentenceID), [favorite.id])
        let repeated = try await model.recordSentenceStudyCompletion(sentenceID: favorite.id)
        XCTAssertEqual(repeated.correctCount, 1)
    }

    func testUnfavoriteAndRefavoriteKeepTheStudyHistory() async throws {
        let model = makeModel()
        let favorite = model.memories[0].sentences[0]
        _ = try await model.recordSentenceStudyCompletion(sentenceID: favorite.id)
        model.deleteFavorite(sentenceID: favorite.id)
        await model.refreshSentenceStudyDueCount()
        XCTAssertTrue(FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: [:]).isEmpty)
        model.toggleFavorite(sentenceID: favorite.id)
        await model.refreshSentenceStudyDueCount()
        let items = FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: model.favoriteSentenceStudyCounts)
        XCTAssertEqual(items.map(\.studyCount), [1])
    }

    func testFavoritesAndEmptyStatesRenderInBothThemes() async throws {
        let model = makeModel()
        replacePhoto(in: model, with: try XCTUnwrap(UIImage(named: "OnboardingCafe")?.jpegData(compressionQuality: 0.8)))
        model.memories[0].sentences += [
            SentenceRecord(english: "Sunlight falls across the little wooden table.", chinese: "阳光洒在小木桌上。", isFavorite: true),
            SentenceRecord(english: "I could sit here with a warm coffee all afternoon.", chinese: "我可以捧着热咖啡在这里坐一整个下午。", isFavorite: true)
        ]
        await model.refreshSentenceStudyDueCount()
        for scheme in [ColorScheme.light, .dark] {
            for state in ["content", "refreshing", "no_favorites", "no_photos"] {
                let memories = model.memories
                defer { model.memories = memories; model.isSyncingRemoteMemories = false }
                if state == "refreshing" { model.isSyncingRemoteMemories = true }
                if state == "no_favorites" {
                    for index in model.memories[0].sentences.indices {
                        model.memories[0].sentences[index].isFavorite = false
                    }
                }
                if state == "no_photos" { model.memories = [] }
                let view = NavigationStack { FavoritesView().environmentObject(model) }
                    .environment(\.colorScheme, scheme)
                let image = try await render(view, size: CGSize(width: 393, height: 720))
                XCTAssertEqual(image.size.width, 393)
                XCTAssertEqual(image.size.height, 720)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Favorites-\(state)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testCompactStudyOverviewFitsOneRowAndKeepsItsSizeWhilePreparing() throws {
        var heights: [CGFloat] = []
        for isPreparing in [false, true] {
            let view = StudyOverviewCard(
                dueCount: 12, studiedCount: 3,
                buttonTitle: L10n.string("study.button.start", "开始学习"),
                isPreparing: isPreparing, canStart: true, isCompact: true, onStart: {}
            ).frame(width: 353)
            let image = try XCTUnwrap(ImageRenderer(content: view).uiImage)
            XCTAssertLessThan(image.size.height, 100, "The default overview should be one compact row")
            heights.append(image.size.height)
        }
        XCTAssertEqual(heights[0], heights[1], accuracy: 1)
    }

    func testLightCardsRenderLongSentencesOnSmallScreensAndWithLargeText() async throws {
        let model = makeModel()
        replacePhoto(in: model, with: try XCTUnwrap(UIImage(named: "OnboardingCafe")?.jpegData(compressionQuality: 0.8)))
        model.memories[0].sentences[0] = SentenceRecord(
            english: "The little cafe is full of warm afternoon light, and my coffee is finally ready.",
            chinese: "咖啡馆里洒满温暖的午后阳光。", isFavorite: true
        )
        let item = try XCTUnwrap(FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: [:]).first)
        for size in [DynamicTypeSize.large, .accessibility3] {
            let row = FavoriteSentenceCard(item: item).environmentObject(model)
                .frame(width: 280)
                .environment(\.dynamicTypeSize, size)
            let measured = try XCTUnwrap(ImageRenderer(content: row).uiImage)
            XCTAssertEqual(measured.size.width, 280)
            XCTAssertGreaterThan(measured.size.height, 150, "Long sentences must wrap fully to the right of the thumbnail")
            let image = try await render(
                row.frame(maxHeight: .infinity).background(AppSurfaceColor.page),
                size: CGSize(width: 320, height: measured.size.height + 80)
            )
            let attachment = XCTAttachment(image: image)
            attachment.name = "Favorites-LongSentence-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testLightCardsDoNotShowTranslationOrStudyMetadata() throws {
        let model = makeModel()
        let item = try XCTUnwrap(FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: [:]).first)
        let before = try XCTUnwrap(ImageRenderer(content:
            FavoriteSentenceCard(item: item).environmentObject(model).frame(width: 353)
        ).uiImage)
        let sentence = SentenceRecord(
            id: item.id, english: item.favorite.sentence.english,
            chinese: String(repeating: "这段翻译不应该出现在收藏列表。", count: 10),
            isFavorite: true
        )
        let changed = FavoriteSentenceListItem(
            favorite: FavoriteSentence(memoryID: item.favorite.memoryID, sentence: sentence),
            createdAt: .distantPast, studyCount: 999
        )
        let after = try XCTUnwrap(ImageRenderer(content:
            FavoriteSentenceCard(item: changed).environmentObject(model).frame(width: 353)
        ).uiImage)
        XCTAssertEqual(before.size, after.size)
        XCTAssertEqual(before.pngData(), after.pngData(),
                       "Translations, dates and study counts must not appear on the card")
    }

    func testLightCardRestoresItsThumbnailWithoutResizingWhenThePhotoArrives() async throws {
        let model = makeModel()
        let item = try XCTUnwrap(FavoriteSentenceListItem.makeItems(memories: model.memories, studyCounts: [:]).first)
        let data = try coloredPhoto(.green)
        let card = FavoriteSentenceCard(item: item).environmentObject(model).frame(width: 353)
            .frame(maxHeight: .infinity, alignment: .top).background(AppSurfaceColor.page)
            .ignoresSafeArea()
        let before = try XCTUnwrap(ImageRenderer(content:
            FavoriteSentenceCard(item: item).environmentObject(model).frame(width: 353)
        ).uiImage).size
        let image = try await render(card, size: CGSize(width: 353, height: before.height + 40)) {
            self.replacePhoto(in: model, with: data)
        }
        XCTAssertEqual(try pixel(image, at: CGPoint(x: 58, y: before.height / 2)), [0, 255, 0, 255])
        let after = try XCTUnwrap(ImageRenderer(content:
            FavoriteSentenceCard(item: item).environmentObject(model).frame(width: 353)
        ).uiImage).size
        XCTAssertEqual(before, after, "Loading the thumbnail must not shift the English text")
    }

    func testSideBySideCardsGrowToFitLongSentences() throws {
        let model = makeModel()
        for width in [CGFloat(280), 353] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let sizes = try [
                    "A quiet moment.",
                    "The little cafe is full of warm afternoon light, and my coffee is finally ready."
                ].map { english in
                    let item = FavoriteSentenceListItem(
                        favorite: FavoriteSentence(memoryID: model.memories[0].id,
                            sentence: SentenceRecord(english: english, chinese: "", isFavorite: true)),
                        createdAt: .now, studyCount: 0
                    )
                    return try XCTUnwrap(ImageRenderer(content:
                        FavoriteSentenceCard(item: item).environmentObject(model).frame(width: width)
                            .environment(\.dynamicTypeSize, typeSize)
                    ).uiImage).size
                }
                XCTAssertEqual(sizes[0].width, width)
                XCTAssertEqual(sizes[1].width, width)
                XCTAssertGreaterThan(sizes[1].height, sizes[0].height,
                                     "The card must grow with its English text instead of clipping it")
            }
        }
    }

    func testThumbnailDecoderRejectsInvalidDataAndReusesSmallImages() throws {
        XCTAssertNil(FavoriteThumbnailDecoder.decode(Data()))
        XCTAssertNil(FavoriteThumbnailDecoder.decode(Data("not an image".utf8)))
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        }
        let data = try XCTUnwrap(photo.jpegData(compressionQuality: 0.8))
        let decoded = try XCTUnwrap(FavoriteThumbnailDecoder.decode(data))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 256)
        XCTAssertTrue(decoded === FavoriteThumbnailDecoder.decode(data))
    }

    func testThumbnailUpdatesWhenPhotoArrivesAfterTheList() async throws {
        let model = makeModel()
        let data = try coloredPhoto(.green)
        let view = FavoriteSentenceThumbnail(memoryID: model.memories[0].id).environmentObject(model)
            .frame(width: 68, height: 68)
            .frame(width: 100, height: 100)
            .ignoresSafeArea()
        let image = try await render(view, size: CGSize(width: 100, height: 100)) {
            self.replacePhoto(in: model, with: data)
        }
        XCTAssertEqual(try centerPixel(image), [0, 255, 0, 255])
    }

    func testThumbnailDoesNotKeepThePreviousAccountsImage() async throws {
        let model = makeModel()
        replacePhoto(in: model, with: try coloredPhoto(.red))
        let newData = try coloredPhoto(.blue)
        let view = FavoriteSentenceThumbnail(memoryID: model.memories[0].id).environmentObject(model)
            .frame(width: 68, height: 68)
            .frame(width: 100, height: 100)
            .ignoresSafeArea()
        let image = try await render(view, size: CGSize(width: 100, height: 100)) {
            model.accountRequests.invalidate()
            self.replacePhoto(in: model, with: newData)
        }
        XCTAssertEqual(try centerPixel(image), [0, 0, 255, 255])
    }

    private func coloredPhoto(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        return try XCTUnwrap(image.pngData())
    }

    private func replacePhoto(in model: AppModel, with data: Data) {
        let memory = model.memories[0]
        model.memories[0] = MemoryEntry(
            id: memory.id, createdAt: memory.createdAt, imageData: data,
            remoteImagePath: memory.remoteImagePath, syncedToAccount: memory.syncedToAccount,
            tags: memory.tags, sentences: memory.sentences
        )
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        try pixel(image, at: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixel = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    private func render<Content: View>(
        _ content: Content, size: CGSize, update: (() -> Void)? = nil
    ) async throws -> UIImage {
        let controller = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        if let update {
            update()
            try await Task.sleep(for: .milliseconds(350))
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func makeModel() -> AppModel {
        let model = AppModel()
        model.localSentenceStudyProgress = [:]
        model.memories = [MemoryEntry(imageData: Data(), sentences: [
            SentenceRecord(english: "The coffee smells really good.", chinese: "咖啡闻起来很香。", isFavorite: true),
            SentenceRecord(english: "The cup is on the table.", chinese: "杯子在桌上。")
        ])]
        model.memoryLoadState = .loaded
        model.favoriteSentencesCount = 1
        return model
    }
}
