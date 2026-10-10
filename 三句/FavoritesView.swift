import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var appModel: AppModel

    private struct RefreshIdentity: Hashable {
        let accountRevision: UUID
        let sentenceIDs: Set<UUID>
    }

    private var favoriteItems: [FavoriteSentenceListItem] {
        FavoriteSentenceListItem.makeItems(
            memories: appModel.memories,
            studyCounts: appModel.favoriteSentenceStudyCounts
        )
    }

    private var refreshIdentity: RefreshIdentity {
        RefreshIdentity(
            accountRevision: appModel.accountRequests.revision,
            sentenceIDs: Set(favoriteItems.map(\.id))
        )
    }

    private var contentState: PhotoContentState {
        PhotoContentState.resolve(
            hasContent: !favoriteItems.isEmpty,
            isLoading: appModel.isRestoringAuthenticatedSession || appModel.isSyncingRemoteMemories
                || appModel.memoryLoadState == .loading,
            hasError: appModel.memoryLoadState == .failed
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: AppSpacing.section) {
                    switch contentState {
                    case .content:
                        studyOverview
                        LazyVStack(spacing: AppSpacing.large) {
                            ForEach(favoriteItems) { item in
                                FavoriteSentenceCard(item: item)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            appModel.deleteFavorite(sentenceID: item.id)
                                        } label: {
                                            Label(L10n.string("favorites.action.unfavorite", "取消收藏"), systemImage: "star.slash")
                                        }
                                    }
                            }
                            ContentFooterHint(isLoading: appModel.isSyncingRemoteMemories)
                                .padding(.top, AppSpacing.small)
                        }
                        .accessibilityIdentifier("favorites.sentence_list")
                    case .loading:
                        ProgressView().controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: emptyStateHeight(in: geometry))
                    case .failed:
                        ContentLoadFailureState { Task { await refreshContent() } }
                            .frame(minHeight: emptyStateHeight(in: geometry))
                    case .empty:
                        if appModel.memories.isEmpty {
                            AddPhotoEmptyState(destination: .favorites) {
                                appModel.selectedTab = .newLearning
                            }
                            .frame(minHeight: emptyStateHeight(in: geometry))
                        } else {
                            EmptyStateView(
                                title: L10n.string("favorites.empty.title", "还没有收藏"),
                                subtitle: L10n.string("favorites.empty.subtitle", "在生成结果中收藏想反复学习的句子，它们就会出现在这里。"),
                                systemImage: "star"
                            )
                            .frame(maxWidth: .infinity, minHeight: emptyStateHeight(in: geometry))
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xLarge)
                .padding(.top, AppSpacing.xLarge)
                .padding(.bottom, AppSpacing.section)
            }
            .refreshable { await refreshContent() }
        }
        .background(AppSurfaceColor.page)
        .navigationTitle(L10n.string("tab.favorites", "收藏"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .task(id: refreshIdentity) { await appModel.refreshSentenceStudyDueCount() }
        .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: sentenceStudyErrorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                appModel.sentenceStudyErrorMessage = nil
            }
        } message: {
            Text(appModel.sentenceStudyErrorMessage ?? "")
        }
        .fullScreenCover(isPresented: $appModel.isShowingSentenceStudySession, onDismiss: {
            Task { await appModel.refreshSentenceStudyDueCount() }
        }) {
            SentenceStudySessionView(
                queue: appModel.sentenceStudyQueue,
                startsInReviewMode: appModel.isRepeatingSentenceStudyQueue
            )
            .environmentObject(appModel)
        }
    }

    private var studyOverview: some View {
        StudyOverviewCard(
            dueCount: appModel.sentenceStudyDueCount,
            studiedCount: appModel.sentenceStudyTodayCount,
            buttonTitle: studyButtonTitle,
            isPreparing: appModel.isLoadingSentenceStudyQueue,
            canStart: appModel.canStartSentenceStudy,
            isCompact: true
        ) {
            Task { await appModel.startSentenceStudy() }
        }
        .accessibilityIdentifier("favorites.study_overview")
    }

    private var studyButtonTitle: String {
        if appModel.isLoadingSentenceStudyQueue {
            return L10n.string("study.button.preparing", "正在准备学习内容...")
        }
        if appModel.hasNewSentenceStudyContent {
            return L10n.string("study.button.start", "开始学习")
        }
        if appModel.hasSentenceStudyReviewContent {
            return L10n.string("study.button.review_again", "再学一遍")
        }
        return L10n.string("study.button.done_today", "今天学完了")
    }

    private var sentenceStudyErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.sentenceStudyErrorMessage != nil },
            set: { if !$0 { appModel.sentenceStudyErrorMessage = nil } }
        )
    }

    private func emptyStateHeight(in geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.height - AppSpacing.xLarge - AppSpacing.section)
    }

    private func refreshContent() async {
        if appModel.isSignedIn {
            await appModel.refreshRemoteContent()
        } else {
            await appModel.refreshSentenceStudyDueCount()
        }
    }
}

struct FavoriteSentenceListItem: Identifiable, Hashable {
    let favorite: FavoriteSentence
    let createdAt: Date
    let studyCount: Int

    var id: UUID { favorite.id }

    static func makeItems(memories: [MemoryEntry], studyCounts: [UUID: Int]) -> [Self] {
        memories.sorted { $0.createdAt > $1.createdAt }.flatMap { memory in
            memory.sentences.filter(\.isFavorite).map { sentence in
                Self(
                    favorite: FavoriteSentence(memoryID: memory.id, sentence: sentence),
                    createdAt: memory.createdAt,
                    studyCount: studyCounts[sentence.id] ?? 0
                )
            }
        }
    }
}

struct FavoriteSentenceCard: View {
    @EnvironmentObject private var appModel: AppModel
    let item: FavoriteSentenceListItem
    private let thumbnailSide: CGFloat = 68

    var body: some View {
        NavigationLink {
            SentenceDetailView(memoryID: item.favorite.memoryID, sentenceID: item.id)
                .toolbar(.visible, for: .navigationBar)
        } label: {
            HStack(spacing: AppSpacing.xLarge) {
                FavoriteSentenceThumbnail(memoryID: item.favorite.memoryID)
                    .frame(width: thumbnailSide, height: thumbnailSide)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
                    .accessibilityHidden(true)

                Text(item.favorite.sentence.english)
                    .font(AppTypography.sentence)
                    .foregroundStyle(AppTextColor.primary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpacing.section)
            .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        }
        .buttonStyle(FavoriteSentenceCardPressStyle())
        .accessibilityIdentifier("favorites.sentence.\(item.id.uuidString)")
        .accessibilityAction(named: L10n.string("favorites.action.unfavorite", "取消收藏")) {
            appModel.deleteFavorite(sentenceID: item.id)
        }
    }
}

private struct FavoriteSentenceCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
