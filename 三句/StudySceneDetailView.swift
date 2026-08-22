import SwiftUI

struct StudySceneDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let route: StudySceneDetailRoute

    @State private var sceneItems: [SentenceStudyQueueItem] = []
    @State private var isLoading = true
    @State private var isStartingStudy = false
    @State private var studySession: SentenceStudyTopicSession?
    @State private var errorMessage: String?
    @State private var refreshedSceneSummary: SentenceStudyTopicSummary?

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

    private var studySummary: SentenceStudyTopicSummary {
        switch route {
        case .favorites:
            return appModel.sentenceStudyTopicSummaries[.favorites] ?? .empty
        case let .userScene(scene):
            return refreshedSceneSummary ?? scene.summary
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
                studyOverviewBar
                sentenceContent
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, AppSpacing.xxxLarge)
        }
    }

    @ViewBuilder
    private var sentenceContent: some View {
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

    private var studyOverviewBar: some View {
        HStack(spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.medium) {
                StudyTopicMetricView(
                    value: "\(studySummary.dueCount)",
                    label: L10n.string("study.metric.due_today", "今日待学")
                )

                Rectangle()
                    .fill(AppStroke.subtle)
                    .frame(width: 1, height: 34)

                StudyTopicMetricView(
                    value: "\(studySummary.studiedCount)",
                    label: L10n.string("study.metric.studied_today", "今日已学")
                )
            }
            .padding(.leading, AppSpacing.xSmall)

            Spacer(minLength: 0)

            Button {
                Task { await startStudy() }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    if isStartingStudy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(studyButtonTitle)
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppControlPadding.prominent)
                .frame(height: AppControlHeight.regular)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: canStartStudy ? [
                                    Color(red: 0.98, green: 0.67, blue: 0.18),
                                    Color(red: 0.91, green: 0.52, blue: 0.17)
                                ] : [
                                    Color(red: 0.86, green: 0.79, blue: 0.72),
                                    Color(red: 0.82, green: 0.75, blue: 0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStartStudy || isStartingStudy)
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppSurfaceColor.card,
                            AppSurfaceColor.elevated
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.highlight, lineWidth: 1)
        }
        .appCardShadow()
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
            await appModel.refreshSentenceStudyDueCount()
        case let .userScene(scene):
            do {
                sceneItems = try await appModel.loadUserStudySceneDetailSentences(for: scene)
                await appModel.refreshUserStudySceneSummaries()
                refreshedSceneSummary = appModel.userStudySceneSummaries
                    .first(where: { $0.id == scene.id })?
                    .summary
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
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(Color.orange)
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
                .foregroundStyle(Color.orange)
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
        .appCardShadow()
    }
}
