import SwiftUI

struct AlbumFlipView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var deck: AlbumFlipDeck
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
    private let ownerID: String
    private let onChooseAnotherPhoto: (() -> Void)?

    private struct FavoriteFeedback {
        let id = UUID()
        let cardID: UUID
        let isFavorite: Bool
    }

    init(
        items: [AlbumFlipItem], ownerID: String, defaults: UserDefaults = .standard,
        mode: AlbumFlipMode = .continuous, onChooseAnotherPhoto: (() -> Void)? = nil
    ) {
        self.ownerID = ownerID
        self.onChooseAnotherPhoto = onChooseAnotherPhoto
        _deck = StateObject(wrappedValue: AlbumFlipDeck(
            items: items, store: AlbumFlipHistoryStore(defaults: defaults, ownerID: ownerID), mode: mode
        ))
    }

    init(deck: AlbumFlipDeck, ownerID: String, onChooseAnotherPhoto: (() -> Void)? = nil) {
        self.ownerID = ownerID
        self.onChooseAnotherPhoto = onChooseAnotherPhoto
        _deck = StateObject(wrappedValue: deck)
    }

    var body: some View {
        GeometryReader { proxy in
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
                        cardStack(size: size, exitWidth: proxy.size.width)
                            .frame(width: area.size.width, height: area.size.height, alignment: .top)
                    }
                    .padding(.top, 18)

                    footer(exitWidth: proxy.size.width)
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
        .onAppear {
            isVisible = true
            deck.onFeedback = { [weak model = appModel] in model?.albumFlipHistorySync?.uploadPending() }
            appModel.albumFlipHistorySync?.refresh()
            appModel.speech.stop()
            speechPrefetchID = appModel.speech.beginAlbumSpeechPrefetch()
        }
        .task(id: deck.currentPageID) {
            favoriteFeedback = nil
            guard deck.currentItem != nil else {
                if let speechPrefetchID { appModel.speech.pauseAlbumSpeechPrefetch(id: speechPrefetchID) }
                appModel.speech.stop()
                return
            }
            if isVisible, scenePhase == .active, !isMuted,
               spokenCardID != deck.currentPageID, let speechPrefetchID {
                appModel.speech.prioritizeAlbumCurrentSentence(id: speechPrefetchID)
            }
            updateSpeechLookahead()
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
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
        .onChange(of: appModel.albumFlipHistoryRevision) { _, _ in
            if appModel.albumFlipOwnerID == ownerID { deck.reloadHistory() }
        }
        .onDisappear {
            isVisible = false
            deck.onFeedback = nil
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
        let progress = min(abs(drag.width) / max(1, size.width * 0.7), 1)
        return ZStack {
            RoundedRectangle(cornerRadius: AppCornerRadius.card)
                .fill(AppStroke.subtle)
                .frame(width: size.width, height: size.height)
                .scaleEffect(reduceMotion ? 0.94 : 0.88 + 0.06 * progress, anchor: .bottom)
                .offset(y: reduceMotion ? 12 : 24 - 12 * progress)
                .accessibilityHidden(true)

            ForEach(Array(deck.visiblePages.reversed())) { page in
                let isFront = page.id == deck.currentPageID
                pageContent(page, size: size, isFront: isFront, exitWidth: exitWidth)
                .overlay(alignment: .top) {
                    if isFront, page.item != nil {
                        swipeBadge
                            .padding(20)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if isFront, let feedback = favoriteFeedback, feedback.cardID == page.id {
                        AlbumFlipFavoriteFeedbackView(isFavorite: feedback.isFavorite)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(isFront ? 0.10 : 0.04), radius: 18, x: 0, y: 10)
                .scaleEffect(isFront || reduceMotion ? 1 : 0.94 + 0.06 * progress, anchor: .bottom)
                .rotationEffect(.degrees(isFront && !reduceMotion ? Double(drag.width / max(1, size.width)) * 13 : 0), anchor: .bottom)
                .offset(x: isFront ? drag.width : 0, y: isFront ? drag.height : (reduceMotion ? 0 : 12 * (1 - progress)))
                .opacity(isFront && reduceMotion && isAdvancing ? 0 : 1)
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
                }
            ) {
                AlbumFlipPhoto(memoryID: card.item.memoryID, isFront: isFront)
            }
            .gesture(TapGesture(count: 2).onEnded { toggleCurrentCardFavorite(cardID: card.id) })
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
            .accessibilityAction(named: L10n.string("album_flip.again", "再看看")) {
                advance(.again, exitWidth: exitWidth)
            }
            .accessibilityAction(named: L10n.string("album_flip.familiar", "熟悉了")) {
                advance(.familiar, exitWidth: exitWidth)
            }
        case .roundBreak:
            AlbumFlipRoundBreakCard(size: size, isPhotoSelectionEnabled: appModel.isNetworkAvailable) {
                guard isVisible, !isAdvancing, deck.isShowingRoundBreak,
                      scenePhase == .active, appModel.albumFlipOwnerID == ownerID,
                      appModel.isNetworkAvailable else { return }
                onChooseAnotherPhoto?()
                close()
            }
            .accessibilityAction(named: L10n.string("album_flip.round.continue", "继续翻一翻")) {
                advance(.familiar, exitWidth: exitWidth)
            }
        }
    }

    private var swipeBadge: some View {
        HStack {
            if drag.width < 0 { Spacer() }
            Label(
                drag.width < 0 ? L10n.string("album_flip.again", "再看看") : L10n.string("album_flip.familiar", "熟悉了"),
                systemImage: drag.width < 0 ? "arrow.uturn.backward" : "checkmark"
            )
            .font(.system(.title3, weight: .bold))
            .foregroundStyle(drag.width < 0 ? AppPalette.accentText : AppPalette.adaptive(0x25624F, 0x93D4B6))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppSurfaceColor.card, in: Capsule())
            .rotationEffect(.degrees(reduceMotion ? 0 : (drag.width < 0 ? 8 : -8)))
            if drag.width >= 0 { Spacer() }
        }
        .opacity(min(abs(drag.width) / 65, 1))
    }

    private func footer(exitWidth: CGFloat) -> some View {
        ZStack {
            controls(exitWidth: exitWidth)
                .opacity(deck.isShowingRoundBreak ? 0 : 1)
                .allowsHitTesting(!deck.isShowingRoundBreak)
                .accessibilityHidden(deck.isShowingRoundBreak)
            if deck.isShowingRoundBreak {
                Button {
                    advance(.familiar, exitWidth: exitWidth)
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

    private func controls(exitWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            feedbackButton(.again, icon: "arrow.uturn.backward", width: exitWidth)
            AlbumFlipReplayButton(speech: appModel.speech, text: deck.currentItem?.sentence.english ?? "") {
                speakCurrentCard(automatically: false)
            }
            .disabled(isAdvancing || deck.currentItem == nil)
            feedbackButton(.familiar, icon: "checkmark", width: exitWidth)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }

    private func feedbackButton(_ feedback: AlbumFlipFeedback, icon: String, width: CGFloat) -> some View {
        Button {
            advance(feedback, exitWidth: width)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 58, height: 58)
                    .background(feedback == .again ? AppSurfaceColor.elevated : AppPalette.accent, in: Circle())
                    .foregroundStyle(feedback == .again ? AppTextColor.primary : AppPalette.onAccent)
                Text(feedback == .again ? L10n.string("album_flip.again", "再看看") : L10n.string("album_flip.familiar", "熟悉了"))
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(AppTextColor.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
        .disabled(isAdvancing)
    }

    private func swipeGesture(cardID: UUID, cardWidth: CGFloat, exitWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isAdvancing, deck.currentPageID == cardID else { return }
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.15
                }
                guard isHorizontalDrag == true else { return }
                drag = CGSize(width: value.translation.width, height: reduceMotion ? 0 : value.translation.height * 0.15)
                crossedThreshold = abs(drag.width) >= cardWidth * 0.25
            }
            .onEnded { value in
                guard !isAdvancing, deck.currentPageID == cardID else { return }
                let wasHorizontal = isHorizontalDrag == true
                isHorizontalDrag = nil
                if wasHorizontal, let result = AlbumFlipSwipe.feedback(
                    x: value.translation.width, y: value.translation.height,
                    predictedX: value.predictedEndTranslation.width, width: cardWidth
                ) {
                    advance(result, exitWidth: exitWidth)
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78)) {
                        drag = .zero
                    }
                    crossedThreshold = false
                }
            }
    }

    private func advance(_ feedback: AlbumFlipFeedback, exitWidth: CGFloat) {
        guard !isAdvancing, isVisible, let pageID = deck.currentPageID,
              appModel.albumFlipOwnerID == ownerID else { return }
        appModel.speech.stop()
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.26), completionCriteria: .removed) {
            isAdvancing = true
            if !reduceMotion {
                drag = CGSize(width: (feedback == .again ? -1 : 1) * (exitWidth + 120), height: drag.height + 25)
            }
        } completion: {
            guard isVisible, appModel.albumFlipOwnerID == ownerID, deck.currentPageID == pageID else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                deck.advance(feedback, cardID: pageID)
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
        appModel.memory(withID: item.memoryID)?.sentences.first(where: { $0.id == item.sentence.id })?.isFavorite ?? false
    }

    private func toggleCurrentCardFavorite(cardID: UUID) {
        guard isVisible, !isAdvancing, scenePhase == .active,
              deck.currentPageID == cardID, let item = deck.currentItem,
              appModel.toggleAlbumFlipSentenceFavorite(item, ownerID: ownerID) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            favoriteFeedback = FavoriteFeedback(cardID: cardID, isFavorite: isFavorite(item))
        }
    }

    private func speakCurrentCard(automatically: Bool) {
        guard isVisible, !isAdvancing, scenePhase == .active,
              appModel.albumFlipOwnerID == ownerID, let pageID = deck.currentPageID,
              let item = deck.currentItem else { return }
        guard !automatically || (!isMuted && spokenCardID != pageID) else { return }
        spokenCardID = pageID
        appModel.speech.speak(item.sentence.english)
    }

    private func close() {
        isVisible = false
        endSpeechLookahead()
        appModel.speech.stop()
        dismiss()
    }

    private func updateSpeechLookahead() {
        guard isVisible, !isAdvancing, appModel.albumFlipOwnerID == ownerID,
              let speechPrefetchID, let current = deck.currentItem else { return }
        appModel.speech.updateAlbumSpeechPrefetch(
            id: speechPrefetchID, current: current.sentence.english,
            upcoming: deck.upcomingSpeechTexts,
            enabled: scenePhase == .active && appModel.isNetworkAvailable
        )
    }

    private func endSpeechLookahead() {
        if let speechPrefetchID { appModel.speech.endAlbumSpeechPrefetch(id: speechPrefetchID) }
        speechPrefetchID = nil
    }
}

enum AlbumFlipLayout {
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
                    Text(L10n.string("album_flip.round.body", "左右滑动，再听一遍这几句话。\n也可以上传新照片，学点新的。"))
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
    let text: String
    let onReplay: () -> Void

    private var playbackState: SpeechPlaybackState {
        SpeechPlaybackState(text: text, activeText: speech.activeText, loadingText: speech.loadingText)
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
    }
}
