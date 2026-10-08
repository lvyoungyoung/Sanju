import SwiftUI
import UIKit

struct StudyView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var errorMessage: String?
    @State private var creationErrorMessage: String?
    @State private var isShowingCreateScene = false
    @State private var newSceneName = ""
    @State private var selectedSuggestedTopicID: String?
    @StateObject private var sceneSuggestions = StudySceneSuggestions()
    @State private var isCreatingScene = false
    @State private var scenePendingDeletion: UserStudySceneSummary?
    @State private var isDeletingScene = false
    @State private var isStartingFavoriteStudy = false
    @State private var favoriteStudySession: SentenceStudyTopicSession?
    @State private var pageTitleOriginY: CGFloat?
    @State private var pageTitleMinY: CGFloat = 0
    private var isLoadingStudyTopics: Bool {
        appModel.studySceneLoadState == .loading || appModel.studySceneLoadState == .idle
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: contentState == .empty ? AppSpacing.large : AppSpacing.section) {
                pageHeader

                switch contentState {
                case .loading:
                    topicListLoadingState.padding(.top, 80)
                case .empty:
                    AddPhotoEmptyState(destination: .study) {
                        appModel.selectedTab = .newLearning
                    }
                    .padding(.top, 36)
                case .failed:
                    ContentLoadFailureState {
                        Task { await refreshStudyOverview() }
                    }
                    .padding(.top, 36)
                case .content:
                    studyContent
                }
            }
            .padding(.horizontal, AppSpacing.section)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, AppSpacing.section)
        }
        .coordinateSpace(name: StudyPageScrollMetrics.coordinateSpaceName)
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(StudyPageTitleMinYPreferenceKey.self) { minY in
            if pageTitleOriginY == nil {
                pageTitleOriginY = minY
            }
            pageTitleMinY = minY
        }
        .task(id: appModel.isRestoringAuthenticatedSession ? nil : appModel.supabaseSession?.userID) {
            guard !appModel.isRestoringAuthenticatedSession else { return }
            await refreshStudyOverview()
        }
        .refreshable {
            await appModel.refreshSentenceStudyDueCount()
        }
        .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: errorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            L10n.string("study.scene.delete_confirmation_title", "删除这个学习主题？"),
            isPresented: sceneDeletionAlertBinding,
            presenting: scenePendingDeletion
        ) { scene in
            Button(L10n.string("common.delete", "删除"), role: .destructive) {
                Task { await deleteScene(scene) }
            }
            Button(L10n.string("common.cancel", "取消"), role: .cancel) {}
        } message: { _ in
            Text(
                L10n.string(
                    "study.scene.delete_confirmation_message",
                    "删除后，该主题的匹配结果和学习记录将被清除，原始回忆和句子不会受到影响。"
                )
            )
        }
        .sheet(isPresented: $isShowingCreateScene) {
            CreateStudySceneSheet(
                sceneName: $newSceneName,
                selectedSuggestedTopicID: $selectedSuggestedTopicID,
                suggestions: sceneSuggestions,
                isCreating: isCreatingScene,
                onCreate: createScene
            )
            .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: creationErrorAlertBinding) {
                Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                    creationErrorMessage = nil
                }
            } message: {
                Text(creationErrorMessage ?? "")
            }
            .presentationDetents([.height(320)])
            .presentationBackground(AppSurfaceColor.page)
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $favoriteStudySession) { session in
            SentenceStudySessionView(
                queue: session.queue,
                studyTopic: session.topic,
                startsInReviewMode: session.startsInReviewMode,
                repeatsActiveQueueOnCompletion: true,
                onDismiss: {
                    favoriteStudySession = nil
                    Task {
                        await appModel.refreshSentenceStudyDueCount()
                        await appModel.refreshUserStudySceneSummaries()
                    }
                }
            )
            .environmentObject(appModel)
        }
    }

    private var contentState: PhotoContentState {
        .resolve(
            hasContent: !appModel.memories.isEmpty || appModel.memorySentenceCount > 0 || !appModel.userStudySceneSummaries.isEmpty,
            isLoading: appModel.studyOverviewLoadState == .idle || appModel.studyOverviewLoadState == .loading || appModel.isRestoringAuthenticatedSession || appModel.isSyncingRemoteMemories,
            hasError: appModel.studyOverviewLoadState == .failed
        )
    }

    private var studyContent: some View {
        Group {
            favoriteStudySection

            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                topicSectionHeader

                LazyVStack(spacing: AppSpacing.medium) {
                    if isLoadingStudyTopics && appModel.userStudySceneSummaries.isEmpty {
                        topicListLoadingState
                    } else if appModel.studySceneLoadState == .failed && appModel.userStudySceneSummaries.isEmpty {
                        ContentLoadFailureState {
                            Task { await refreshStudyOverview() }
                        }
                    } else if appModel.userStudySceneSummaries.isEmpty {
                        topicListEmptyState
                    } else {
                        ForEach(appModel.userStudySceneSummaries) { scene in
                            userStudySceneCard(scene)
                        }
                    }
                }
            }
            .padding(.top, AppSpacing.medium)
        }
    }

    private var pageHeader: some View {
        Text(L10n.string("study.topic.page_title", "学习"))
            .font(AppTypography.pageTitle)
            .foregroundStyle(AppTextColor.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(pageTitleOpacity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StudyPageTitleMinYPreferenceKey.self,
                        value: proxy.frame(in: .named(StudyPageScrollMetrics.coordinateSpaceName)).minY
                    )
                }
            }
    }

    private var pageTitleOpacity: Double {
        guard let pageTitleOriginY else { return 1 }
        let fadeDistance: CGFloat = 64
        return min(1, max(0, Double((pageTitleMinY - pageTitleOriginY + fadeDistance) / fadeDistance)))
    }

    private var favoriteSummary: SentenceStudyTopicSummary {
        let cachedSummary = appModel.sentenceStudyTopicSummaries[.favorites] ?? .empty
        return SentenceStudyTopicSummary(
            totalCount: appModel.favorites.count,
            dueCount: cachedSummary.dueCount,
            studiedCount: cachedSummary.studiedCount,
            reviewableTodayCount: cachedSummary.reviewableTodayCount,
            masteryScore: cachedSummary.masteryScore
        )
    }

    private var favoriteStudySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("study.topic.favorites", "收藏"))
                .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)

                Spacer(minLength: AppSpacing.small)

                NavigationLink(value: StudySceneDetailRoute.favorites) {
                    Text(L10n.string("study.topic.view_all", "查看全部"))
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(AppPalette.accentText)
                }
                .buttonStyle(.plain)
            }

            favoriteStudyOverview(summary: favoriteSummary)
        }
    }

    private var topicSectionHeader: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small / 3) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Text(L10n.string("study.topic.section_title", "我的学习主题"))
                    .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)

                Spacer(minLength: AppSpacing.small)

                if !appModel.userStudySceneSummaries.isEmpty {
                    Button(action: showCreateScene) {
                        Label(L10n.string("common.create", "创建"), systemImage: "plus")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                            .foregroundStyle(AppPalette.accentText)
                            .fixedSize()
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("study.scene.create", "创建我的学习主题"))
                }
            }

            if !appModel.userStudySceneSummaries.isEmpty {
                Text(L10n.string("study.topic.section_description", "创建你的语言使用场景，AI会把已经生成的句子匹配到各个场景中"))
                    .font(.subheadline)
                    .foregroundStyle(AppTextColor.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topicListLoadingState: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(AppPalette.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .accessibilityLabel(L10n.string("study.topic.loading", "正在加载学习主题..."))
    }

    private var topicListEmptyState: some View {
        VStack(spacing: AppSpacing.xLarge) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AppTextColor.tertiary)
                .frame(height: 88)
                .accessibilityHidden(true)

            Text(L10n.string("study.topic.section_description", "创建你的语言使用场景，AI会把已经生成的句子匹配到各个场景中"))
                .font(.subheadline)
                .foregroundStyle(AppTextColor.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            createSceneButton
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxxLarge)
    }

    private var createSceneButton: some View {
        Button(action: showCreateScene) {
            Label(
                L10n.string("study.scene.create", "创建我的学习主题"),
                systemImage: "plus"
            )
            .font(.system(size: AppFontSize.body, weight: .semibold))
            .foregroundStyle(AppPalette.accentText)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(AppSurfaceColor.card)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .stroke(AppPalette.accent.opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func userStudySceneCard(_ scene: UserStudySceneSummary) -> some View {
        let tint = sceneTint(for: scene)
        let coverRequest = scene.coverMemoryID.flatMap { appModel.pendingMemoryImageRequest(memoryID: $0) }

        return NavigationLink(value: StudySceneDetailRoute.userScene(scene)) {
            sceneListCardContent(scene: scene, tint: tint)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                scenePendingDeletion = scene
            } label: {
                Label(
                    L10n.string("study.scene.delete", "删除学习主题"),
                    systemImage: "trash"
                )
            }
        }
        .disabled(isDeletingScene)
        .task(id: coverRequest) {
            guard let coverRequest else { return }
            await appModel.ensureMemoryImageLoaded(memoryID: coverRequest.memoryID)
        }
    }

    private func sceneListCardContent(
        scene: UserStudySceneSummary,
        tint: Color
    ) -> some View {
        let coverImage = scene.coverMemoryID.flatMap(memoryImage(for:))

        return topicListCardContent(
            title: scene.name,
            summary: scene.summary,
            coverImage: coverImage,
            tint: tint
        )
    }

    private func topicListCardContent(
        title: String,
        summary: SentenceStudyTopicSummary,
        coverImage: UIImage?,
        tint: Color
    ) -> some View {
        HStack(spacing: AppSpacing.xLarge) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(title)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)

                Text(
                    L10n.string(
                        "study.scene.detail.sentence_count",
                        "共 %d 句",
                        summary.totalCount
                    )
                )
                .font(.system(size: AppFontSize.metadata, weight: .medium))
                .foregroundStyle(AppTextColor.secondary)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(AppSurfaceColor.subtleFill)

                        Capsule()
                            .fill(AppPalette.accent)
                            .frame(width: proxy.size.width * CGFloat(min(max(summary.masteryScore, 0), 100)) / 100)
                    }
                }
                    .frame(width: 110, height: 8)
                    .padding(.top, 5)
                    .accessibilityLabel(
                        L10n.string(
                            "study.topic.mastery",
                            "掌握度 %d%%",
                            summary.masteryScore
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sceneCover(image: coverImage, tint: tint)
        }
        .padding(AppSpacing.medium)
        .padding(.leading, AppSpacing.small)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .appCardBorder()
    }

    @ViewBuilder
    private func sceneCover(image: UIImage?, tint: Color) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: AppIconSize.regular, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.14))
            }
        }
        .frame(width: 112, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
        .allowsHitTesting(false)
    }

    private func favoriteStudyOverview(summary: SentenceStudyTopicSummary) -> some View {
        StudyOverviewCard(
            dueCount: summary.dueCount,
            studiedCount: summary.reviewableTodayCount,
            buttonTitle: favoriteStudyButtonTitle,
            isPreparing: isStartingFavoriteStudy,
            canStart: canStartFavoriteStudy,
            onStart: { Task { await startFavoriteStudy() } }
        )
    }

    private var canStartFavoriteStudy: Bool {
        favoriteSummary.dueCount > 0 || favoriteSummary.reviewableTodayCount > 0
    }

    private var favoriteStudyButtonTitle: String {
        if isStartingFavoriteStudy {
            return L10n.string("study.button.preparing", "正在准备学习内容...")
        }
        if favoriteSummary.dueCount > 0 {
            return L10n.string("study.button.start", "开始学习")
        }
        if favoriteSummary.reviewableTodayCount > 0 {
            return L10n.string("study.button.review_again", "再学一遍")
        }
        return L10n.string("study.button.done_today", "今天学完了")
    }

    private func sceneTint(for scene: UserStudySceneSummary) -> Color {
        let palette: [Color] = [
            Color(red: 0.29, green: 0.56, blue: 0.86),
            Color(red: 0.24, green: 0.58, blue: 0.40),
            Color(red: 0.86, green: 0.45, blue: 0.18),
            Color(red: 0.56, green: 0.40, blue: 0.78),
            Color(red: 0.76, green: 0.38, blue: 0.45),
            Color(red: 0.40, green: 0.45, blue: 0.60)
        ]
        let index = scene.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count
        return palette[index]
    }

    private func memoryImage(for memoryID: UUID) -> UIImage? {
        guard let imageData = appModel.memories.first(where: { $0.id == memoryID })?.imageData,
              !imageData.isEmpty else {
            return nil
        }
        return UIImage(data: imageData)
    }

    private func showCreateScene() {
        guard appModel.isSignedIn else {
            appModel.isShowingSignInSheet = true
            return
        }
        guard StudySceneCreationPolicy.canCreate(currentCount: appModel.userStudySceneSummaries.count) else {
            errorMessage = StudySceneCreationPolicy.limitMessage
            return
        }
        creationErrorMessage = nil
        newSceneName = ""
        selectedSuggestedTopicID = nil
        sceneSuggestions.prepare(
            accountRevision: appModel.accountRequests.revision,
            localTopicIDs: Set(appModel.memories.flatMap(\.sentences).flatMap(\.learningTopicIDs))
        )
        sceneSuggestions.shuffle()
        isShowingCreateScene = true
    }

    private func refreshStudyOverview() async {
        if !appModel.isSignedIn, appModel.loadStoredSession()?.isAnonymous == false {
            await appModel.ensureRemoteSessionRestoreCompleted()
        }
        await appModel.refreshSentenceStudyDueCount()
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private var sceneDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { scenePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    scenePendingDeletion = nil
                }
            }
        )
    }

    private var creationErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { creationErrorMessage != nil },
            set: { if !$0 { creationErrorMessage = nil } }
        )
    }

    @MainActor
    private func createScene() async {
        guard !isCreatingScene else { return }
        let name = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isCreatingScene = true
        defer { isCreatingScene = false }

        do {
            let learningTopicID =
                selectedSuggestedTopicID ?? LearningTopic.topic(matchingName: name)?.id
            let scene = try await appModel.createUserStudyScene(
                named: name,
                learningTopicID: learningTopicID
            )
            isShowingCreateScene = false
            newSceneName = ""
            selectedSuggestedTopicID = nil
            appModel.studyNavigationPath.append(.userScene(scene))
        } catch {
            creationErrorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.scene.create_failed", "暂时无法创建学习主题，请稍后再试。")
                : error.localizedDescription
        }
    }

    @MainActor
    private func deleteScene(_ scene: UserStudySceneSummary) async {
        scenePendingDeletion = nil
        isDeletingScene = true
        defer { isDeletingScene = false }

        do {
            try await appModel.deleteUserStudyScene(scene)
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.scene.delete_failed", "暂时无法删除学习主题，请稍后再试。")
                : error.localizedDescription
        }
    }

    @MainActor
    private func startFavoriteStudy() async {
        isStartingFavoriteStudy = true
        defer { isStartingFavoriteStudy = false }

        do {
            guard let session = try await appModel.loadSentenceStudyTopicSession(for: .favorites) else {
                errorMessage = L10n.string("study.topic.empty.action_hint", "这个主题暂时没有可学习的句子。")
                return
            }
            favoriteStudySession = session
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                : error.localizedDescription
        }
    }
}

private struct StudyTopicOverviewMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(value, format: .number)
            .font(.system(size: AppFontSize.stat, weight: .bold))
            .foregroundStyle(AppTextColor.title)
            .monospacedDigit()

            Text(label)
                .font(.system(size: AppFontSize.caption, weight: .medium))
                .foregroundStyle(AppTextColor.tertiary)
        }
        .frame(minWidth: 54, alignment: .leading)
    }
}

private enum StudyPageScrollMetrics {
    static let coordinateSpaceName = "study-page-scroll"
}

private struct StudyPageTitleMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CreateStudySceneSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var sceneName: String
    @Binding var selectedSuggestedTopicID: String?
    @ObservedObject var suggestions: StudySceneSuggestions
    @FocusState private var isSceneNameFocused: Bool
    @State private var suggestionsRefreshID = UUID()
    let isCreating: Bool
    let onCreate: () async -> Void

    var body: some View {
        ScrollView {
            formContent
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: isCreating) { _, creating in
            if creating { isSceneNameFocused = false }
        }
        .task(id: "\(appModel.accountRequests.revision)-\(suggestionsRefreshID)") {
            await suggestions.refresh(
                accountRevision: appModel.accountRequests.revision,
                localTopicIDs: learningTopicSignature
            ) {
                try await appModel.fetchStudySceneSuggestionTopicIDs()
            }
        }
        .onDisappear {
            suggestions.cancelLoading()
        }
        .onChange(of: learningTopicSignature) { _, topicIDs in
            suggestions.prepare(accountRevision: appModel.accountRequests.revision, localTopicIDs: topicIDs)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack(spacing: AppSpacing.small) {
                if let selectedTopic = LearningTopic.topic(for: selectedSuggestedTopicID) {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text(selectedTopic.title)
                            .font(.system(size: AppFontSize.body, weight: .medium))
                            .foregroundStyle(AppPalette.accentText)

                        Button {
                            selectedSuggestedTopicID = nil
                            sceneName = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: AppIconSize.compact, weight: .bold))
                                .foregroundStyle(AppPalette.accent.opacity(0.78))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            L10n.string(
                                "study.scene.remove_selected_suggestion",
                                "移除已选主题"
                            )
                        )
                    }
                    .padding(.leading, AppSpacing.medium)
                    .padding(.trailing, AppSpacing.xSmall)
                    .frame(height: 34)
                    .background(AppPalette.accent.opacity(0.14), in: Capsule())

                    Spacer(minLength: 0)
                } else {
                    TextField(
                        L10n.string("study.scene.name_placeholder", "输入你想学习的主题"),
                        text: $sceneName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSceneNameFocused)
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .frame(height: 50)
            .background(
                AppSurfaceColor.elevated,
                in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(
                        selectedSuggestedTopicID != nil || isSceneNameFocused ? AppPalette.accent.opacity(0.72) : AppStroke.soft,
                        lineWidth: selectedSuggestedTopicID != nil || isSceneNameFocused ? 1.5 : 1
                    )
            }
            .disabled(isCreating)
            .opacity(isCreating ? 0.5 : 1)

            StudySceneSuggestionSection(
                suggestions: suggestions,
                selectedTopicID: selectedSuggestedTopicID,
                onRefresh: {
                    if suggestions.displayedTopics.isEmpty || suggestions.loadState == .failed {
                        suggestionsRefreshID = UUID()
                    } else {
                        suggestions.shuffle()
                    }
                },
                onSelect: { topic in
                    sceneName = topic.title
                    selectedSuggestedTopicID = topic.id
                    isSceneNameFocused = false
                }
            )
            .disabled(isCreating)
            .opacity(isCreating ? 0.5 : 1)

            Button {
                isSceneNameFocused = false
                Task { await onCreate() }
            } label: {
                Group {
                    if isCreating {
                        HStack(spacing: AppSpacing.small) {
                            ProgressView().tint(AppTextColor.inverse)
                            Text(L10n.string("study.scene.creating", "正在整理主题..."))
                                .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        }
                    } else {
                        Text(L10n.string("common.create", "创建"))
                            .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(AppTextColor.inverse)
                .background(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSurfaceColor.subtleFill : AppPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isCreating || sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(AppSpacing.xLarge)
    }

    private var learningTopicSignature: Set<String> {
        Set(appModel.memories
            .flatMap(\.sentences)
            .flatMap(\.learningTopicIDs))
    }
}
