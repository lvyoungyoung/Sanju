import SwiftUI

struct StudySceneDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let route: StudySceneDetailRoute

    @State private var sceneItems: [SentenceStudyQueueItem] = []
    @State private var isLoading = true
    @State private var isStartingStudy = false
    @State private var studySession: SentenceStudyTopicSession?
    @State private var errorMessage: String?

    private var title: String { route.title }

    private var items: [StudySceneDetailSentence] {
        switch route {
        case .favorites:
            return appModel.memories
                .sorted { $0.createdAt > $1.createdAt }
                .flatMap { memory in
                    memory.sentences.filter(\.isFavorite).map { sentence in
                        StudySceneDetailSentence(
                            id: sentence.id,
                            english: sentence.english,
                            chinese: sentence.chinese,
                            createdAt: memory.createdAt,
                            studyCount: appModel.favoriteSentenceStudyCounts[sentence.id] ?? 0
                        )
                    }
                }
        case .userScene:
            return sceneItems.map {
                StudySceneDetailSentence(
                    id: $0.sentenceID,
                    english: $0.english,
                    chinese: $0.chinese,
                    createdAt: $0.createdAt,
                    studyCount: $0.correctCount
                )
            }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                loadingState
            } else {
                detailContent
            }
        }
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: route) {
            await loadDetail()
        }
        .refreshable {
            await loadDetail()
        }
        .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: errorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .fullScreenCover(item: $studySession) { session in
            SentenceStudySessionView(
                queue: session.queue,
                studyTopic: session.topic,
                startsInReviewMode: session.startsInReviewMode,
                repeatsActiveQueueOnCompletion: true,
                onDismiss: {
                    studySession = nil
                    Task {
                        await appModel.refreshSentenceStudyDueCount()
                        await loadDetail()
                    }
                }
            )
            .environmentObject(appModel)
        }
    }

    private var loadingState: some View {
        ScrollView {
            SyncLoadingState(
                title: L10n.string("study.scene.detail.loading_title", "正在寻找这个主题的句子"),
                subtitle: L10n.string("study.scene.detail.loading_subtitle", "马上就好，正在整理相关表达")
            )
            .padding(.top, 170)
        }
    }

    private var detailContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                sceneHeader

                if items.isEmpty {
                    EmptyStateView(
                        title: L10n.string("study.scene.detail.empty_title", "暂未找到匹配句子"),
                        subtitle: L10n.string("study.scene.detail.empty_subtitle", "以后生成相关画面时，它们会自动出现在这里。"),
                        systemImage: "text.badge.xmark"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: AppSpacing.medium) {
                        ForEach(items) { item in
                            StudySceneDetailSentenceCard(
                                item: item,
                                canUnfavorite: route.isFavorites
                            )
                        }
                        ContentFooterHint(isLoading: false)
                            .padding(.top, AppSpacing.small)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 92)
        }
        .safeAreaInset(edge: .bottom) {
            studyButton
        }
    }

    private var sceneHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(L10n.string("study.scene.detail.all_sentences", "全部句子"))
                .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                .foregroundStyle(AppTextColor.secondary)

            Text(
                L10n.string(
                    "study.scene.detail.sentence_count",
                    "共 %d 句",
                    items.count
                )
            )
            .font(.system(size: AppFontSize.bodyProminent, weight: .bold))
            .foregroundStyle(AppTextColor.primary)
        }
    }

    private var studyButton: some View {
        Button {
            Task { await startStudy() }
        } label: {
            Group {
                if isStartingStudy {
                    ProgressView()
                        .tint(AppTextColor.inverse)
                } else {
                    Label(
                        L10n.string("study.scene.detail.start", "去学习"),
                        systemImage: "book.closed.fill"
                    )
                        .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                }
            }
            .frame(minWidth: 116)
            .padding(.horizontal, AppSpacing.large)
            .frame(height: AppControlHeight.regular)
            .foregroundStyle(AppTextColor.inverse)
            .background(items.isEmpty ? AppSurfaceColor.subtleFill : Color.orange, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty || isStartingStudy)
        .appSurfaceShadow()
        .frame(maxWidth: .infinity)
        .padding(.bottom, AppSpacing.large)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    @MainActor
    private func loadDetail() async {
        isLoading = true
        defer { isLoading = false }

        switch route {
        case .favorites:
            await appModel.refreshFavoriteSentenceStudyCounts()
        case let .userScene(scene):
            do {
                sceneItems = try await appModel.loadUserStudySceneDetailSentences(for: scene)
            } catch {
                errorMessage = error.localizedDescription.isEmpty
                    ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                    : error.localizedDescription
            }
        }
    }

    @MainActor
    private func startStudy() async {
        isStartingStudy = true
        defer { isStartingStudy = false }

        do {
            let session: SentenceStudyTopicSession?
            switch route {
            case .favorites:
                session = try await appModel.loadSentenceStudyTopicSession(for: .favorites)
            case let .userScene(scene):
                session = try await appModel.loadUserStudySceneSession(for: scene)
            }

            guard let session else {
                errorMessage = L10n.string("study.topic.empty.action_hint", "这个主题暂时没有可学习的句子。")
                return
            }
            studySession = session
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                : error.localizedDescription
        }
    }
}

private extension StudySceneDetailRoute {
    var isFavorites: Bool {
        if case .favorites = self {
            return true
        }
        return false
    }
}

private struct StudySceneDetailSentence: Identifiable, Hashable {
    let id: UUID
    let english: String
    let chinese: String
    let createdAt: Date
    let studyCount: Int
}

private struct StudySceneDetailSentenceCard: View {
    @EnvironmentObject private var appModel: AppModel
    let item: StudySceneDetailSentence
    let canUnfavorite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack(alignment: .top) {
                Text(item.english)
                    .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appModel.speech.speak(item.english)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                        .frame(width: AppControlHeight.compact, height: AppControlHeight.compact)
                        .background(AppSurfaceColor.elevated, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(item.chinese)
                .font(.system(size: AppFontSize.sectionLabel))
                .foregroundStyle(AppTextColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Label(formattedDate, systemImage: "calendar")
                    .font(.system(size: AppFontSize.caption, weight: .medium))
                    .foregroundStyle(AppTextColor.tertiary)

                Spacer(minLength: AppSpacing.medium)

                Label(
                    L10n.string("favorites.study_count", "已学 %d 次", item.studyCount),
                    systemImage: "checkmark.circle"
                )
                .font(.system(size: AppFontSize.caption, weight: .medium))
                .foregroundStyle(AppTextColor.tertiary)
            }
        }
        .padding(AppSpacing.xLarge)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardShadow()
        .contextMenu {
            if canUnfavorite {
                Button(role: .destructive) {
                    appModel.deleteFavorite(sentenceID: item.id)
                } label: {
                    Label(
                        L10n.string("favorites.action.unfavorite", "取消收藏"),
                        systemImage: "star.slash"
                    )
                }
            }
        }
    }

    private var formattedDate: String {
        Self.dateFormatter.string(from: item.createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()
}
