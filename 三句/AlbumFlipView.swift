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
    private let ownerID: String

    init(items: [AlbumFlipItem], ownerID: String, defaults: UserDefaults = .standard) {
        self.ownerID = ownerID
        _deck = StateObject(wrappedValue: AlbumFlipDeck(
            items: items, store: AlbumFlipHistoryStore(defaults: defaults, ownerID: ownerID)
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                if deck.cards.isEmpty {
                    ContentUnavailableView(
                        L10n.string("album_flip.empty", "还没有可以翻看的句子"),
                        systemImage: "photo.on.rectangle"
                    )
                } else {
                    GeometryReader { area in
                        let width = min(max(0, area.size.width - 48), 520)
                        let height = max(0, area.size.height - 36)
                        cardStack(size: CGSize(width: width, height: height), exitWidth: proxy.size.width)
                            .frame(width: area.size.width, height: area.size.height, alignment: .top)
                    }
                    .padding(.top, 18)

                    controls(exitWidth: proxy.size.width)
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
        .task(id: deck.cards.first?.id) {
            guard deck.cards.first != nil else { return }
            if isVisible, scenePhase == .active, !isMuted,
               spokenCardID != deck.cards.first?.id, let speechPrefetchID {
                appModel.speech.prioritizeAlbumCurrentSentence(id: speechPrefetchID)
            }
            updateSpeechLookahead()
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            speakCurrentCard(automatically: true)
            updateSpeechLookahead()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the background must not unexpectedly restart narration.
            if phase != .active {
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
            VStack(spacing: 3) {
                Text(L10n.string("album_flip.title", "我的英语相册"))
                    .font(.system(.headline, weight: .semibold))
                Text(L10n.string("album_flip.count", "已翻看 %d 句", deck.viewedCount))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppTextColor.secondary)
                    .contentTransition(.numericText())
            }
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

            ForEach(Array(deck.visibleCards.reversed())) { card in
                let isFront = card.id == deck.cards.first?.id
                AlbumFlipSentenceCard(
                    item: card.item,
                    size: size,
                    showsTranslation: isFront && showsTranslation,
                    onToggleTranslation: {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            showsTranslation.toggle()
                        }
                    }
                ) {
                    AlbumFlipPhoto(memoryID: card.item.memoryID)
                }
                .overlay(alignment: .top) {
                    if isFront {
                        swipeBadge
                            .padding(20)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .shadow(color: .black.opacity(isFront ? 0.10 : 0.04), radius: 18, x: 0, y: 10)
                .scaleEffect(isFront || reduceMotion ? 1 : 0.94 + 0.06 * progress, anchor: .bottom)
                .rotationEffect(.degrees(isFront && !reduceMotion ? Double(drag.width / max(1, size.width)) * 13 : 0), anchor: .bottom)
                .offset(x: isFront ? drag.width : 0, y: isFront ? drag.height : (reduceMotion ? 0 : 12 * (1 - progress)))
                .opacity(isFront && reduceMotion && isAdvancing ? 0 : 1)
                .allowsHitTesting(isFront && !isAdvancing)
                .accessibilityHidden(!isFront)
                .simultaneousGesture(swipeGesture(cardID: card.id, cardWidth: size.width, exitWidth: exitWidth))
                .accessibilityAction(named: L10n.string("album_flip.again", "再看看")) {
                    advance(.again, exitWidth: exitWidth)
                }
                .accessibilityAction(named: L10n.string("album_flip.familiar", "熟悉了")) {
                    advance(.familiar, exitWidth: exitWidth)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .sensoryFeedback(.selection, trigger: crossedThreshold)
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

    private func controls(exitWidth: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 20) {
                feedbackButton(.again, icon: "arrow.uturn.backward", width: exitWidth)
                if let card = deck.cards.first {
                    AlbumFlipReplayButton(speech: appModel.speech, text: card.item.sentence.english) {
                        speakCurrentCard(automatically: false)
                    }
                        .disabled(isAdvancing)
                }
                feedbackButton(.familiar, icon: "checkmark", width: exitWidth)
            }
            .frame(maxWidth: 460)
            Text(L10n.string("album_flip.hint", "左滑再看看，右滑熟悉了"))
                .font(.caption)
                .foregroundStyle(AppTextColor.secondary)
                .multilineTextAlignment(.center)
        }
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
                guard !isAdvancing, deck.cards.first?.id == cardID else { return }
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height) * 1.15
                }
                guard isHorizontalDrag == true else { return }
                drag = CGSize(width: value.translation.width, height: reduceMotion ? 0 : value.translation.height * 0.15)
                crossedThreshold = abs(drag.width) >= cardWidth * 0.25
            }
            .onEnded { value in
                guard !isAdvancing, deck.cards.first?.id == cardID else { return }
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
        guard !isAdvancing, isVisible, let card = deck.cards.first,
              appModel.albumFlipOwnerID == ownerID else { return }
        appModel.speech.stop()
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.26), completionCriteria: .removed) {
            isAdvancing = true
            if !reduceMotion {
                drag = CGSize(width: (feedback == .again ? -1 : 1) * (exitWidth + 120), height: drag.height + 25)
            }
        } completion: {
            guard isVisible, appModel.albumFlipOwnerID == ownerID, deck.cards.first?.id == card.id else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                deck.advance(feedback, cardID: card.id)
                drag = .zero
                isAdvancing = false
                isHorizontalDrag = nil
                showsTranslation = false
                crossedThreshold = false
            }
        }
    }

    private func speakCurrentCard(automatically: Bool) {
        guard isVisible, !isAdvancing, scenePhase == .active,
              appModel.albumFlipOwnerID == ownerID, let card = deck.cards.first else { return }
        guard !automatically || (!isMuted && spokenCardID != card.id) else { return }
        spokenCardID = card.id
        appModel.speech.speak(card.item.sentence.english)
    }

    private func close() {
        isVisible = false
        endSpeechLookahead()
        appModel.speech.stop()
        dismiss()
    }

    private func updateSpeechLookahead() {
        guard isVisible, !isAdvancing, appModel.albumFlipOwnerID == ownerID,
              let speechPrefetchID, let current = deck.cards.first else { return }
        appModel.speech.updateAlbumSpeechPrefetch(
            id: speechPrefetchID, current: current.item.sentence.english,
            upcoming: deck.upcomingSpeechTexts,
            enabled: scenePhase == .active && appModel.isNetworkAvailable
        )
    }

    private func endSpeechLookahead() {
        if let speechPrefetchID { appModel.speech.endAlbumSpeechPrefetch(id: speechPrefetchID) }
        speechPrefetchID = nil
    }
}

extension AppModel {
    var albumFlipOwnerID: String {
        isSignedIn ? (supabaseSession?.userID ?? "guest") : "guest"
    }
}

private struct AlbumFlipReplayButton: View {
    @ObservedObject var speech: SpeechService
    let text: String
    let onReplay: () -> Void

    var body: some View {
        Button(action: onReplay) {
            SpeechPlaybackLabel(speech: speech, text: text, icon: "speaker.wave.2")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTextColor.primary)
                .frame(width: 52, height: 52)
                .background(AppSurfaceColor.card, in: Circle())
        }
        .buttonStyle(StudioPressStyle())
        .accessibilityLabel(L10n.string("album_flip.replay", "再听一遍"))
        .padding(.bottom, 22)
    }
}
