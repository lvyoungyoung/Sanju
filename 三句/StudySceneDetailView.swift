import SwiftUI

struct StudySceneDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let route: StudySceneDetailRoute

    @State private var sceneItems: [SentenceStudyQueueItem] = []
    @State private var isLoading = true
    @State private var isStartingStudy = false
    @State private var studySession: SentenceStudyTopicSession?
    @State private var errorMessage: String?
    @State private var refreshedSceneSummary: SentenceStudyTopicSummary?
    @State private var detailLoadID = UUID()
    @State private var showsSlowLoadingHint = false
    @State private var matchSettings: StudySceneMatchSettings?
    @State private var showsMatchSettings = false
    @State private var enrichmentStatus: StudySceneEnrichmentStatus?
    @State private var enrichmentCheckFailed = false
    @State private var enrichmentPollID = UUID()

    private struct LoadContext: Equatable {
        let route: StudySceneDetailRoute
        let userID: String?
        let isActive: Bool
    }

    private var isDeepSearching: Bool {
        !route.isFavorites && !enrichmentCheckFailed && enrichmentStatus?.isPending == true
    }

    private var title: String {
        switch route {
        case .favorites:
            return L10n.string("study.topic.favorites_count", "收藏（%d）", appModel.favorites.count)
        case .userScene:
            return route.title
        }
    }

    private var cachedSceneItems: [SentenceStudyQueueItem]? {
        guard case let .userScene(scene) = route else { return nil }
        return appModel.cachedUserStudySceneDetailSentences(for: scene.id)
    }

    private var shouldShowInitialLoading: Bool {
        guard case .userScene = route else { return false }
        return isLoading && sceneItems.isEmpty && (cachedSceneItems?.isEmpty ?? true)
    }

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
            return (sceneItems.isEmpty ? cachedSceneItems ?? [] : sceneItems).map {
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

    private var studySummary: SentenceStudyTopicSummary {
        switch route {
        case .favorites:
            return appModel.sentenceStudyTopicSummaries[.favorites] ?? .empty
        case let .userScene(scene):
            return appModel.userStudySceneSummaries.first(where: { $0.id == scene.id })?.summary
                ?? refreshedSceneSummary ?? scene.summary
        }
    }

    private var canStartStudy: Bool {
        studySummary.dueCount > 0 || studySummary.reviewableTodayCount > 0
    }

    private var studyButtonTitle: String {
        if isStartingStudy {
            return L10n.string("study.button.preparing", "正在准备学习内容...")
        }
        if studySummary.dueCount > 0 {
            return L10n.string("study.button.start", "开始学习")
        }
        if studySummary.reviewableTodayCount > 0 {
            return L10n.string("study.button.review_again", "再学一遍")
        }
        return L10n.string("study.button.done_today", "今天学完了")
    }

    var body: some View {
        Group {
            if shouldShowInitialLoading {
                loadingState
            } else {
                detailContent
            }
        }
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if matchSettings?.canAdjust == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsMatchSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("study.match.title", "匹配范围"))
                    .disabled(isLoading || isStartingStudy)
                }
            }
        }
        .sheet(isPresented: $showsMatchSettings) {
            if let settings = matchSettings {
                StudyMatchSettingsSheet(settings: settings, save: { threshold in
                    detailLoadID = UUID()
                    let updated = try await appModel.saveStudySceneMatchSettings(sceneID: settings.sceneID, threshold: threshold)
                    matchSettings = updated
                    return updated
                }, didSave: {
                    await loadDetail(forceRefresh: true)
                })
            }
        }
        .task(id: LoadContext(route: route, userID: appModel.supabaseSession?.userID, isActive: scenePhase == .active)) {
            enrichmentPollID = UUID()
            guard scenePhase == .active else { return }
            await loadDetail()
        }
        .task(id: enrichmentPollID) {
            await monitorEnrichment()
        }
        .refreshable {
            await loadDetail(forceRefresh: true)
        }
        .onDisappear {
            detailLoadID = UUID()
            enrichmentPollID = UUID()
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
                        await loadDetail(forceRefresh: true)
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
                subtitle: showsSlowLoadingHint
                    ? L10n.string("study.scene.detail.loading_slow_subtitle", "首次寻找主题下的句子可能耗时较长，请稍后")
                    : L10n.string("study.scene.detail.loading_subtitle", "马上就好，正在整理相关表达")
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, AppSpacing.section)
            .padding(.top, 170)
        }
        .task(id: detailLoadID) {
            showsSlowLoadingHint = false
            do {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
                showsSlowLoadingHint = true
            } catch is CancellationError {
                // Leaving the loading state cancels its delayed hint.
            } catch {
                return
            }
        }
    }

    private var detailContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                enrichmentNotice
                studyOverviewBar
                sentenceContent
            }
            .padding(.horizontal, AppSpacing.section)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, AppSpacing.xxxLarge)
        }
    }

    @ViewBuilder
    private var sentenceContent: some View {
        if items.isEmpty && (isDeepSearching || enrichmentCheckFailed || (enrichmentStatus?.failedCount ?? 0) > 0) {
            Color.clear.frame(height: 60)
        } else if items.isEmpty {
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

    @ViewBuilder
    private var enrichmentNotice: some View {
        if isDeepSearching {
            HStack(alignment: .top, spacing: AppSpacing.medium) {
                ProgressView().controlSize(.small)
                Text(L10n.string("study.scene.detail.deep_search", "正在深度查找句子，结果将陆续更新。"))
                    .font(.system(size: AppFontSize.caption))
                    .foregroundStyle(AppTextColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !route.isFavorites && (enrichmentCheckFailed || (enrichmentStatus?.failedCount ?? 0) > 0) {
            Text(L10n.string("study.scene.detail.deep_search_incomplete", "部分句子暂未完成查找，当前结果可能不完整。"))
                .font(.system(size: AppFontSize.caption))
                .foregroundStyle(AppTextColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var studyOverviewBar: some View {
        StudyOverviewCard(
            dueCount: studySummary.dueCount,
            studiedCount: studySummary.reviewableTodayCount,
            buttonTitle: studyButtonTitle,
            isPreparing: isStartingStudy,
            canStart: canStartStudy,
            onStart: { Task { await startStudy() } }
        )
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
    private func loadDetail(forceRefresh: Bool = false) async {
        enrichmentPollID = UUID()
        let loadID = UUID()
        detailLoadID = loadID
        let hasCachedItems = cachedSceneItems != nil
        isLoading = !hasCachedItems
        defer {
            if detailLoadID == loadID {
                isLoading = false
                enrichmentPollID = UUID()
            }
        }

        switch route {
        case .favorites:
            await appModel.refreshSentenceStudyDueCount()
        case let .userScene(scene):
            if let cachedSceneItems, !forceRefresh {
                sceneItems = cachedSceneItems
            }
            do {
                do {
                    let status = try await appModel.continueStudySceneEnrichment(sceneID: scene.id)
                    guard detailLoadID == loadID, !Task.isCancelled else { return }
                    enrichmentStatus = status
                    enrichmentCheckFailed = false
                } catch {
                    guard detailLoadID == loadID, !Task.isCancelled, !(error is CancellationError) else { return }
                    enrichmentCheckFailed = true
                }
                let settings = try await appModel.loadStudySceneMatchSettings(sceneID: scene.id)
                guard detailLoadID == loadID, !Task.isCancelled else { return }
                matchSettings = settings
                let refreshedItems = try await appModel.refreshUserStudySceneDetailSentences(for: scene, ifCurrent: {
                    detailLoadID == loadID
                })
                guard detailLoadID == loadID, !Task.isCancelled else { return }
                sceneItems = refreshedItems
                isLoading = false
                await appModel.refreshUserStudySceneSummaries()
                guard detailLoadID == loadID, !Task.isCancelled else { return }
                refreshedSceneSummary = appModel.userStudySceneSummaries
                    .first(where: { $0.id == scene.id })?.summary
            } catch {
                guard detailLoadID == loadID, !Task.isCancelled, !(error is CancellationError) else { return }
                if !hasCachedItems || forceRefresh {
                    errorMessage = error.localizedDescription.isEmpty
                        ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                        : error.localizedDescription
                }
            }
        }

    }

    @MainActor
    private func monitorEnrichment() async {
        guard case let .userScene(scene) = route, !isLoading, scenePhase == .active else { return }
        let loadID = detailLoadID
        let userID = appModel.supabaseSession?.userID
        while isDeepSearching && !Task.isCancelled && scenePhase == .active {
            do {
                try await Task.sleep(for: .seconds(enrichmentStatus?.pollingDelay ?? 5))
                let status = try await appModel.continueStudySceneEnrichment(sceneID: scene.id)
                guard detailLoadID == loadID, appModel.supabaseSession?.userID == userID, !Task.isCancelled else { return }
                if status.completedCount != enrichmentStatus?.completedCount || !status.isPending {
                    let updated = try await appModel.refreshUserStudySceneDetailSentences(for: scene, ifCurrent: {
                        detailLoadID == loadID && appModel.supabaseSession?.userID == userID
                    })
                    guard detailLoadID == loadID, !Task.isCancelled else { return }
                    sceneItems = updated
                    await appModel.refreshUserStudySceneSummaries()
                    guard detailLoadID == loadID, appModel.supabaseSession?.userID == userID, !Task.isCancelled else { return }
                    refreshedSceneSummary = appModel.userStudySceneSummaries.first(where: { $0.id == scene.id })?.summary
                }
                enrichmentStatus = status
            } catch {
                guard detailLoadID == loadID, appModel.supabaseSession?.userID == userID,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                enrichmentCheckFailed = true
                return
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

private struct StudyTopicMetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(value)
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
                    SpeechPlaybackLabel(speech: appModel.speech, text: item.english)
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(AppPalette.accentText)
                        .frame(width: AppControlHeight.compact, height: AppControlHeight.compact)
                        .background(AppSurfaceColor.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("new.result.play", "播放"))
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
        .appCardBorder()
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

private struct StudyTopicExpressionCard: View {
    @EnvironmentObject private var appModel: AppModel
    let expression: StudyTopicExpression
    @State private var showsExamples = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack(alignment: .top, spacing: AppSpacing.medium) {
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    Text(expression.english)
                        .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                        .foregroundStyle(AppTextColor.primary)

                    if let partOfSpeech = expression.partOfSpeech,
                       !partOfSpeech.isEmpty {
                        Text(partOfSpeech)
                            .font(.system(size: AppFontSize.caption, weight: .medium))
                            .foregroundStyle(AppTextColor.tertiary)
                    }
                }

                Spacer(minLength: AppSpacing.medium)

                Button {
                    appModel.speech.speak(expression.english)
                } label: {
                    SpeechPlaybackLabel(speech: appModel.speech, text: expression.english, icon: "speaker.wave.2.fill")
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(AppPalette.accentText)
                        .frame(width: AppControlHeight.compact, height: AppControlHeight.compact)
                        .background(AppSurfaceColor.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("study.scene.detail.play_pronunciation", "播放发音"))
            }

            Text(expression.chinese)
                .font(.system(size: AppFontSize.sectionLabel))
                .foregroundStyle(AppTextColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(
                L10n.string(
                    "study.scene.detail.expression_count",
                    "在本主题中出现 %d 次",
                    expression.occurrenceCount
                )
            )
            .font(.system(size: AppFontSize.caption, weight: .medium))
            .foregroundStyle(AppTextColor.tertiary)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsExamples.toggle()
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Text(L10n.string("study.scene.detail.view_examples", "查看例句"))
                    Image(systemName: showsExamples ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: AppFontSize.body, weight: .semibold))
                .foregroundStyle(AppPalette.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if showsExamples {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    ForEach(expression.examples) { example in
                        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                            Text(example.english)
                                .font(.system(size: AppFontSize.body, weight: .medium))
                                .foregroundStyle(AppTextColor.primary)
                            Text(example.chinese)
                                .font(.system(size: AppFontSize.caption))
                                .foregroundStyle(AppTextColor.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if example.id != expression.examples.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(AppSpacing.large)
                .background(AppSurfaceColor.subtleFill, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
            }
        }
        .padding(AppSpacing.xLarge)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardBorder()
    }
}
