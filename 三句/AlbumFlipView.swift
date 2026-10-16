import Combine
import PhotosUI
import SwiftUI

@MainActor
final class AlbumFlipPhotoSelection: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var selectedItem: PhotosPickerItem?

    func begin() {
        selectedItem = nil
        isPresented = true
    }

    func select(_ item: PhotosPickerItem?) {
        guard isPresented else { return }
        selectedItem = item
        if item != nil { isPresented = false }
    }

    func takeSelectionAfterDismissal() -> PhotosPickerItem? {
        guard !isPresented else { return nil }
        defer { selectedItem = nil }
        return selectedItem
    }
}

struct AlbumFlipView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var deck: AlbumFlipDeck
    @StateObject private var photoSelection = AlbumFlipPhotoSelection()
    @State private var drag = CGSize.zero
    @State private var isHorizontalDrag: Bool?
    @State private var isAdvancing = false
    @State private var isVisible = false
    @State private var showsTranslation = false
    @State private var isMuted = false
    @State private var crossedThreshold = false
    @State private var spokenCardID: UUID?
    @State private var speechPrefetchID: UUID?
    @State private var favoriteFeedback: FavoriteFeedback?
    @State private var photoToPrepare: PhotosPickerItem?
    @State private var isPreparingPhoto = false
    @State private var showsPhotoReadError = false
    private let ownerID: String
    private let onSelectAnotherPhoto: ((PhotosPickerItem) async -> Bool)?

    private struct FavoriteFeedback {
        let id = UUID()
        let cardID: UUID
        let isFavorite: Bool
        let showsDoubleTapHint: Bool
    }

    init(
        items: [AlbumFlipItem], ownerID: String,
        mode: AlbumFlipMode = .continuous, onSelectAnotherPhoto: ((PhotosPickerItem) async -> Bool)? = nil
    ) {
        self.ownerID = ownerID
        self.onSelectAnotherPhoto = onSelectAnotherPhoto
        _deck = StateObject(wrappedValue: AlbumFlipDeck(
            items: items, mode: mode
        ))
    }

    init(
        deck: AlbumFlipDeck, ownerID: String,
        photoSelection: AlbumFlipPhotoSelection? = nil,
        onSelectAnotherPhoto: ((PhotosPickerItem) async -> Bool)? = nil
    ) {
        self.ownerID = ownerID
        self.onSelectAnotherPhoto = onSelectAnotherPhoto
        _deck = StateObject(wrappedValue: deck)
        _photoSelection = StateObject(wrappedValue: photoSelection ?? AlbumFlipPhotoSelection())
    }

    var body: some View {
        GeometryReader { proxy in
            let pageStride = AlbumFlipLayout.pageStride(in: proxy.size.width)
            VStack(spacing: 0) {
                header
                if deck.currentPageID == nil {
                    ContentUnavailableView(
                        L10n.string("album_flip.empty", "还没有可以翻看的句子"),
                        systemImage: "photo.on.rectangle"
                    )
                } else {
                    GeometryReader { area in
                        let size = AlbumFlipLayout.cardSize(in: area.size)
                        cardStack(size: size, exitWidth: pageStride)
                            .frame(width: area.size.width, height: area.size.height, alignment: .top)
                    }
                    .padding(.top, 18)

                    footer(exitWidth: pageStride)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        // Keep the full-screen background outside the swipe content's clipping region.
        .background(AppSurfaceColor.page.ignoresSafeArea())
        .overlay {
            if isPreparingPhoto {
                ZStack {
                    AppSurfaceColor.page.opacity(0.7)
                    ProgressView()
                }
                .ignoresSafeArea()
            }
        }
        .alert(L10n.string("new.photo.read_failed", "读取图片失败，请重试。"), isPresented: $showsPhotoReadError) {
            Button(L10n.string("common.ok", "好"), role: .cancel) { }
        }
        .task(id: photoToPrepare) {
            guard let item = photoToPrepare, let onSelectAnotherPhoto else { return }
            let ready = await onSelectAnotherPhoto(item)
            guard !Task.isCancelled, isVisible, appModel.albumFlipOwnerID == ownerID else { return }
            isPreparingPhoto = false
            photoToPrepare = nil
            if ready {
                close()
            } else {
                showsPhotoReadError = true
            }
        }
        .photosPicker(
            isPresented: $photoSelection.isPresented,
            selection: Binding(
                get: { photoSelection.selectedItem },
                set: { photoSelection.select($0) }
            ),
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: photoSelection.isPresented) { _, isPresented in
            if !isPresented { finishPhotoSelection() }
        }
        .onAppear {
            isVisible = true
            appModel.speech.stop()
            speechPrefetchID = appModel.speech.beginAlbumSpeechPrefetch()
        }
        .task(id: deck.currentPageID) {
            favoriteFeedback = nil
            let pageID = deck.currentPageID
            appModel.speech.stop()
            spokenCardID = nil
            guard deck.currentItem != nil else {
                if let speechPrefetchID { appModel.speech.pauseAlbumSpeechPrefetch(id: speechPrefetchID) }
                return
            }
            if isVisible, scenePhase == .active, !isMuted,
               spokenCardID != deck.currentPageID, let speechPrefetchID {
                appModel.speech.prioritizeAlbumCurrentSentence(id: speechPrefetchID)
            }
            updateSpeechLookahead()
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled, deck.currentPageID == pageID else { return }
            speakCurrentCard(automatically: true)
            updateSpeechLookahead()
        }
        .task(id: favoriteFeedback?.id) {
            guard let feedback = favoriteFeedback else { return }
            do { try await Task.sleep(for: .seconds(feedback.isFavorite ? 2 : 1)) } catch { return }
            guard favoriteFeedback?.id == feedback.id else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                favoriteFeedback = nil
            }
        }
        .sensoryFeedback(.success, trigger: favoriteFeedback?.id) { _, newID in newID != nil }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the background must not unexpectedly restart narration.
            if phase != .active {
                favoriteFeedback = nil
                if let speechPrefetchID { appModel.speech.pauseAlbumSpeechPrefetch(id: speechPrefetchID) }
                appModel.speech.stop()
                if !isAdvancing {
                    drag = .zero
                    isHorizontalDrag = nil
                    crossedThreshold = false
                }
            } else {
                updateSpeechLookahead()
            }
        }
        .onChange(of: appModel.isNetworkAvailable) { _, _ in
            updateSpeechLookahead()
        }
        .onChange(of: appModel.albumFlipOwnerID) { _, newOwner in
            if newOwner != ownerID { close() }
        }
        .onDisappear {
            isVisible = false
            endSpeechLookahead()
            appModel.speech.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(AppSurfaceColor.elevated, in: Circle())
            }
            .accessibilityLabel(L10n.string("common.close", "关闭"))

            Spacer(minLength: 0)
            Text(L10n.string("album_flip.title", "我的英语相册"))
                .font(.system(.headline, weight: .semibold))
            Spacer(minLength: 0)

            Button {
                isMuted.toggle()
                if isMuted { appModel.speech.stop() } else { speakCurrentCard(automatically: false) }
            } label: {
                Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(AppSurfaceColor.elevated, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isMuted
                ? L10n.string("album_flip.unmute", "开启自动朗读")
                : L10n.string("album_flip.mute", "关闭自动朗读"))
            .disabled(deck.currentPageID == nil)
        }
        .foregroundStyle(AppTextColor.primary)
        .buttonStyle(StudioPressStyle())
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func cardStack(size: CGSize, exitWidth: CGFloat) -> some View {
        return ZStack {
            ForEach(deck.browsingPages) { page in
                let isFront = page.id == deck.currentPageID
                let focus = AlbumFlipPagingMotion.focus(
                    relativePosition: deck.relativePosition(of: page.id),
                    translation: drag.width, pageWidth: exitWidth
                )
                let reveal = isFront ? 1 : AlbumFlipPagingMotion.contentReveal(focus: focus)
                ZStack {
                    // Keep photos warm, but show only abstract shapes at the sides.
                    pageContent(page, size: size, isFront: isFront, exitWidth: exitWidth)
                        .opacity(reveal)
                    AlbumFlipNeighborCard(size: size)
                        .opacity(1 - reveal)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if isFront, let feedback = favoriteFeedback, feedback.cardID == page.id {
                        AlbumFlipFavoriteFeedbackView(
                            isFavorite: feedback.isFavorite, showsDoubleTapHint: feedback.showsDoubleTapHint
                        )
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                    }
                }
                .scaleEffect(x: 1, y: reduceMotion ? 1 : AlbumFlipPagingMotion.heightScale(focus: focus))
                .shadow(color: .black.opacity(isFront ? 0.08 : 0.035), radius: isFront ? 14 : 8, x: 0, y: 8)
                .zIndex(Double(focus))
                .offset(x: reduceMotion ? 0 : AlbumFlipPagingMotion.offset(
                    relativePosition: deck.relativePosition(of: page.id),
                    translation: drag.width, pageWidth: exitWidth
                ))
                .opacity(reduceMotion ? (isFront && !isAdvancing ? 1 : 0) : 1)
                .allowsHitTesting(isFront && !isAdvancing)
                .accessibilityHidden(!isFront)
                .simultaneousGesture(swipeGesture(cardID: page.id, cardWidth: size.width, exitWidth: exitWidth))
            }
        }
        .frame(width: size.width, height: size.height)
        .sensoryFeedback(.selection, trigger: crossedThreshold)
    }

    @ViewBuilder
    private func pageContent(_ page: AlbumFlipPage, size: CGSize, isFront: Bool, exitWidth: CGFloat) -> some View {
        switch page {
        case .sentence(let card):
            AlbumFlipSentenceCard(
                item: card.item, size: size, showsTranslation: isFront && showsTranslation,
                onToggleTranslation: {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        showsTranslation.toggle()
                    }
                },
                showsJapaneseReadings: appModel.showsJapaneseReadings
            ) {
                AlbumFlipPhoto(memoryID: card.item.memoryID, isFront: isFront)
            }
            .gesture(TapGesture(count: 2).onEnded {
                toggleCurrentCardFavorite(cardID: card.id, showsDoubleTapHint: false)
            })
            // Keep the button outside the card's double-tap recognizer.
            .overlay(alignment: .topTrailing) {
                AlbumFlipFavoriteButton(isFavorite: isFavorite(card.item)) {
                    toggleCurrentCardFavorite(cardID: card.id)
                }
                .padding(12)
            }
            .accessibilityAction(named: isFavorite(card.item)
                ? L10n.string("favorites.action.unfavorite", "取消收藏")
                : L10n.string("new.result.favorite", "收藏")) {
                toggleCurrentCardFavorite(cardID: card.id)
            }
            .accessibilityAction(named: L10n.string("album_flip.previous", "上一张")) {
                navigate(.previous, exitWidth: exitWidth)
            }
            .accessibilityAction(named: L10n.string("album_flip.next", "下一张")) {
                navigate(.next, exitWidth: exitWidth)
            }
        case .roundBreak:
            AlbumFlipRoundBreakCard(size: size, isPhotoSelectionEnabled: appModel.isNetworkAvailable && onSelectAnotherPhoto != nil) {
                guard isVisible, !isAdvancing, deck.isShowingRoundBreak,
                      scenePhase == .active, appModel.albumFlipOwnerID == ownerID,
                      appModel.isNetworkAvailable else { return }
                guard onSelectAnotherPhoto != nil else { return }
                appModel.speech.stop()
                if let speechPrefetchID { appModel.speech.pauseAlbumSpeechPrefetch(id: speechPrefetchID) }
                photoSelection.begin()
            }
            .accessibilityAction(named: L10n.string("album_flip.round.continue", "继续翻一翻")) {
                navigate(.next, exitWidth: exitWidth)
            }
            .accessibilityAction(named: L10n.string("album_flip.previous", "上一张")) {
                navigate(.previous, exitWidth: exitWidth)
            }
        }
    }

    private func footer(exitWidth: CGFloat) -> some View {
        ZStack {
            controls
                .opacity(deck.isShowingRoundBreak ? 0 : 1)
                .allowsHitTesting(!deck.isShowingRoundBreak)
                .accessibilityHidden(deck.isShowingRoundBreak)
            if deck.isShowingRoundBreak {
                Button {
                    navigate(.next, exitWidth: exitWidth)
                } label: {
                    Label(L10n.string("album_flip.round.continue", "继续翻一翻"), systemImage: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTextColor.primary)
                        .padding(.horizontal, 24)
                        .frame(minHeight: AppControlHeight.regular)
                        .background(AppSurfaceColor.elevated, in: Capsule())
                }
                .buttonStyle(StudioPressStyle())
                .disabled(isAdvancing)
                .accessibilityIdentifier("album_flip.continue_round")
            }
        }
    }

    private var controls: some View {
        AlbumFlipReplayButton(speech: appModel.speech, requests: deck.currentItem.map { item in
            item.sentences.map { appModel.speech.request(sentence: $0, context: item.context) }
        } ?? []) {
            speakCurrentCard(automatically: false)
        }
        .disabled(isAdvancing || deck.currentItem == nil)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    private func swipeGesture(cardID: UUID, cardWidth: CGFloat, exitWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isAdvancing, deck.currentPageID == cardID else { return }
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.15
                }
                guard isHorizontalDrag == true else { return }
                drag = CGSize(width: AlbumFlipPagingMotion.translation(
                    value.translation.width, pageWidth: exitWidth, canGoBack: deck.canGoBack
                ), height: 0)
                crossedThreshold = (value.translation.width < 0 || deck.canGoBack) && abs(drag.width) >= cardWidth * 0.25
            }
            .onEnded { value in
                guard !isAdvancing, deck.currentPageID == cardID else { return }
                let wasHorizontal = isHorizontalDrag == true
                isHorizontalDrag = nil
                if wasHorizontal, let result = AlbumFlipSwipe.direction(
                    x: value.translation.width, y: value.translation.height,
                    predictedX: value.predictedEndTranslation.width, width: cardWidth
                ) {
                    navigate(result, exitWidth: exitWidth)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78)) {
                        drag = .zero
                    }
                    crossedThreshold = false
                }
            }
    }

    private func navigate(_ direction: AlbumFlipDirection, exitWidth: CGFloat) {
        guard !isAdvancing, isVisible, !photoSelection.isPresented, let pageID = deck.currentPageID,
              scenePhase == .active, appModel.albumFlipOwnerID == ownerID else { return }
        guard direction == .next || deck.canGoBack else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78)) {
                drag = .zero
            }
            crossedThreshold = false
            return
        }
        appModel.speech.stop()
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.28), completionCriteria: .removed) {
            isAdvancing = true
            if !reduceMotion {
                drag = CGSize(width: (direction == .next ? -1 : 1) * exitWidth, height: 0)
            }
        } completion: {
            guard isVisible, appModel.albumFlipOwnerID == ownerID, deck.currentPageID == pageID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                deck.navigate(direction, cardID: pageID)
                drag = .zero
                isAdvancing = false
                isHorizontalDrag = nil
                showsTranslation = false
                crossedThreshold = false
                favoriteFeedback = nil
            }
        }
    }

    private func isFavorite(_ item: AlbumFlipItem) -> Bool {
        guard let memory = appModel.memory(withID: item.memoryID) else { return false }
        return item.sentences.allSatisfy { turn in memory.sentences.first(where: { $0.id == turn.id })?.isFavorite == true }
    }

    private func toggleCurrentCardFavorite(cardID: UUID, showsDoubleTapHint: Bool = true) {
        guard isVisible, !isAdvancing, scenePhase == .active,
              deck.currentPageID == cardID, let item = deck.currentItem,
              appModel.toggleAlbumFlipSentenceFavorite(item, ownerID: ownerID) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            favoriteFeedback = FavoriteFeedback(
                cardID: cardID, isFavorite: isFavorite(item), showsDoubleTapHint: showsDoubleTapHint
            )
        }
    }

    private func speakCurrentCard(automatically: Bool) {
        guard isVisible, !isAdvancing, !photoSelection.isPresented, scenePhase == .active,
              appModel.albumFlipOwnerID == ownerID, let pageID = deck.currentPageID,
              let item = deck.currentItem else { return }
        guard !automatically || (!isMuted && spokenCardID != pageID) else { return }
        spokenCardID = pageID
        let requests = item.sentences.map { appModel.speech.request(sentence: $0, context: item.context) }
        if item.reply == nil {
            appModel.speech.speak(requests[0])
        } else {
            appModel.speech.speakSequence(requests)
        }
    }

    private func finishPhotoSelection() {
        guard let item = photoSelection.takeSelectionAfterDismissal(), isVisible,
              appModel.albumFlipOwnerID == ownerID, onSelectAnotherPhoto != nil else { return }
        // Cancelling the system picker leaves the album and its current card in place.
        // Keep covering the old result until the new photo and cleared result are ready.
        isPreparingPhoto = true
        photoToPrepare = item
    }

    private func close() {
        isVisible = false
        endSpeechLookahead()
        appModel.speech.stop()
        dismiss()
    }

    private func updateSpeechLookahead() {
        guard isVisible, !isAdvancing, !photoSelection.isPresented, appModel.albumFlipOwnerID == ownerID,
              let speechPrefetchID, let current = deck.currentItem else { return }
        appModel.speech.updateAlbumSpeechPrefetch(
            id: speechPrefetchID, current: appModel.speech.request(sentence: current.sentence, context: current.context),
            upcoming: current.sentences.dropFirst().map { appModel.speech.request(sentence: $0, context: current.context) }
                + deck.upcomingSpeechItems.flatMap { item in
                    item.sentences.map { appModel.speech.request(sentence: $0, context: item.context) }
                },
            enabled: scenePhase == .active && appModel.isNetworkAvailable
        )
    }

    private func endSpeechLookahead() {
        if let speechPrefetchID { appModel.speech.endAlbumSpeechPrefetch(id: speechPrefetchID) }
        speechPrefetchID = nil
    }
}

enum AlbumFlipPagingMotion {
    static func focus(relativePosition: Int, translation: CGFloat, pageWidth: CGFloat) -> CGFloat {
        guard pageWidth > 0 else { return relativePosition == 0 ? 1 : 0 }
        return 1 - min(1, abs(offset(relativePosition: relativePosition, translation: translation, pageWidth: pageWidth)) / pageWidth)
    }

    static func heightScale(focus: CGFloat) -> CGFloat { 0.92 + 0.08 * min(1, max(0, focus)) }

    static func contentReveal(focus: CGFloat) -> Double {
        Double(min(1, max(0, (focus - 0.55) / 0.45)))
    }

    static func translation(_ x: CGFloat, pageWidth: CGFloat, canGoBack: Bool) -> CGFloat {
        guard pageWidth > 0 else { return 0 }
        if x > 0 && !canGoBack { return min(x * 0.22, 64) }
        return min(max(x, -pageWidth), pageWidth)
    }

    static func offset(relativePosition: Int, translation: CGFloat, pageWidth: CGFloat) -> CGFloat {
        CGFloat(relativePosition) * pageWidth + translation
    }
}

enum AlbumFlipLayout {
    static func pageStride(in viewportWidth: CGFloat) -> CGFloat {
        let cardWidth = cardSize(in: CGSize(width: viewportWidth, height: 0)).width
        guard cardWidth > 0 else { return 0 }
        // Reveal 10pt of each neighbor without narrowing the current card.
        return max(cardWidth, (viewportWidth + cardWidth) / 2 - 10)
    }

    static func cardSize(in area: CGSize) -> CGSize {
        CGSize(width: min(max(0, area.width - 48), 520), height: max(0, area.height - 36))
    }
}

struct AlbumFlipRoundBreakCard: View {
    let size: CGSize
    let isPhotoSelectionEnabled: Bool
    let onChooseAnotherPhoto: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text(L10n.string("album_flip.round.title", "继续翻，重复听"))
                        .font(.title3.weight(.medium))
                    Text(L10n.string("album_flip.round.body", "继续翻，再听一遍这几句话。\n也可以上传新照片，学点新的。"))
                        .font(.subheadline)
                        .lineSpacing(4)
                }
                Button(action: onChooseAnotherPhoto) {
                    Text(L10n.string("album_flip.complete.choose_another", "再上传一张"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppPalette.onAccent)
                        .padding(.horizontal, 24)
                        .frame(minHeight: AppControlHeight.regular)
                        .background(AppPalette.accent, in: Capsule())
                }
                .buttonStyle(StudioPressStyle())
                .disabled(!isPhotoSelectionEnabled)
                .opacity(isPhotoSelectionEnabled ? 1 : 0.5)
                if !isPhotoSelectionEnabled {
                    Text(L10n.string("new.photo_selection.network_required", "请连接网络"))
                        .font(.subheadline)
                }
            }
            .foregroundStyle(AppTextColor.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: size.width, height: size.height)
        .background {
            AlbumFlipCompletionHatching()
                .stroke(AppTextColor.secondary.opacity(0.13), lineWidth: 1)
                .background(AppSurfaceColor.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous)
                .strokeBorder(AppTextColor.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [7, 6]))
                .allowsHitTesting(false)
        }
    }
}

private struct AlbumFlipCompletionHatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 12
        }
        return path
    }
}

extension AppModel {
    var albumFlipOwnerID: String {
        isSignedIn ? (supabaseSession?.userID ?? "guest") : "guest"
    }
}

private extension SpeechPlaybackState {
    var title: String {
        switch self {
        case .idle: L10n.string("album_flip.replay", "再听一遍")
        case .loading: L10n.string("speech.loading", "正在准备朗读")
        case .playing: L10n.string("album_flip.playing", "朗读中")
        }
    }
}

private struct AlbumFlipReplayButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var speech: SpeechService
    let requests: [SpeechRequest]
    let onReplay: () -> Void

    private var playbackState: SpeechPlaybackState {
        for request in requests {
            let state = SpeechPlaybackState(request: request, activeRequest: speech.activeRequest,
                                            activeText: speech.activeText, loadingText: speech.loadingText)
            if state != .idle { return state }
        }
        return !requests.isEmpty && speech.sequenceRequests == requests ? .playing : .idle
    }

    var body: some View {
        Button(action: onReplay) {
            Group {
                switch playbackState {
                case .idle:
                    Image(systemName: "play.fill")
                case .loading:
                    ProgressView().controlSize(.small)
                case .playing:
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                }
            }
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(playbackState == .playing ? AppPalette.accentText : AppTextColor.primary)
            .frame(width: 58, height: 58)
            .background(AppSurfaceColor.card, in: Circle())
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .accessibilityLabel(L10n.string("album_flip.replay", "再听一遍"))
        .accessibilityValue(playbackState == .idle ? "" : playbackState.title)
        .alert(L10n.string("speech.unavailable.title", "无法播放"), isPresented: Binding(
            get: { speech.playbackError != nil && speech.playbackErrorRequest.map { requests.contains($0) } == true },
            set: { if !$0 { speech.dismissPlaybackError() } }
        )) {
            Button(L10n.string("common.ok", "好"), role: .cancel) { speech.dismissPlaybackError() }
        } message: {
            Text(L10n.string("speech.unavailable.message", "暂时无法播放此语言，请稍后重试，或在系统设置中下载对应语言的声音。"))
        }
    }
}
