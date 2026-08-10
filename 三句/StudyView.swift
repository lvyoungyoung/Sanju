import SwiftUI

struct StudyView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var activeTopic: SentenceStudyTopic?
    @State private var topicSession: SentenceStudyTopicSession?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                header

                if totalAvailableCount == 0 {
                    EmptyStateView(
                        title: L10n.string("study.topic.empty.title", "还没有主题内容"),
                        subtitle: L10n.string("study.topic.empty.subtitle", "完成一次生成后，AI 会自动把句子归入适合学习的主题。"),
                        systemImage: "sparkles"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                } else {
                    LazyVStack(spacing: AppSpacing.medium) {
                        ForEach(studyTopics) { topic in
                            topicCard(topic)
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await appModel.refreshSentenceStudyDueCount()
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
        .fullScreenCover(item: $topicSession) { session in
            SentenceStudySessionView(
                queue: session.queue,
                studyTopic: session.topic,
                startsInReviewMode: session.startsInReviewMode,
                repeatsActiveQueueOnCompletion: true,
                onDismiss: {
                    Task {
                        await appModel.refreshSentenceStudyDueCount()
                    }
                }
            )
            .environmentObject(appModel)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(L10n.string("study.topic.page_title", "学习"))
                .font(.system(size: AppFontSize.pageTitle, weight: .bold))
                .foregroundStyle(AppTextColor.title)

            Text(
                L10n.string(
                    "study.topic.page_subtitle",
                    "按场景练习，让你更自然地说出眼前的画面。"
                )
            )
            .font(.system(size: AppFontSize.body))
            .foregroundStyle(AppTextColor.secondary)

            HStack(spacing: AppSpacing.small) {
                studyMetric(
                    title: L10n.string("study.metric.due_today", "今日待学"),
                    value: topicDueCount
                )
                studyMetric(
                    title: L10n.string("study.metric.studied_today", "今日已学"),
                    value: appModel.sentenceStudyTodayCount
                )
            }
            .padding(.top, AppSpacing.small)
        }
        .padding(AppSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.subtle, lineWidth: 1)
        }
    }

    private func studyMetric(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: AppFontSize.metadata, weight: .medium))
                .foregroundStyle(AppTextColor.secondary)
            Text("\(value)")
                .font(.system(size: AppFontSize.heroStat, weight: .bold, design: .rounded))
                .foregroundStyle(AppTextColor.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.large)
        .background(AppSurfaceColor.elevated, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
    }

    private func topicCard(_ topic: SentenceStudyTopic) -> some View {
        let summary = appModel.sentenceStudyTopicSummaries[topic] ?? .empty
        let action = action(for: summary)

        return HStack(spacing: AppSpacing.large) {
            Image(systemName: topic.iconName)
                .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                .foregroundStyle(topic.tintColor)
                .frame(width: 44, height: 44)
                .background(topic.tintColor.opacity(0.13), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(topic.title)
                    .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)

                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        L10n.string(
                            "study.topic.mastery",
                            "掌握度 %d%%",
                            summary.masteryScore
                        )
                    )
                    .font(.system(size: AppFontSize.metadata, weight: .medium))
                    .foregroundStyle(AppTextColor.secondary)

                    GeometryReader { proxy in
                        Capsule()
                            .fill(AppSurfaceColor.secondaryFill)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(topic.tintColor)
                                    .frame(width: proxy.size.width * CGFloat(summary.masteryScore) / 100)
                            }
                    }
                    .frame(height: 5)
                }
            }

            Spacer(minLength: AppSpacing.small)

            Button {
                Task { await start(topic) }
            } label: {
                Group {
                    if activeTopic == topic {
                        ProgressView()
                            .tint(action.isEnabled ? AppTextColor.inverse : AppTextColor.secondary)
                    } else {
                        Text(action.title)
                            .font(.system(size: AppFontSize.metadata, weight: .semibold))
                    }
                }
                .frame(minWidth: 76)
                .frame(height: AppControlHeight.compact)
                .foregroundStyle(action.isEnabled ? AppTextColor.inverse : AppTextColor.secondary)
                .background(action.isEnabled ? topic.tintColor : AppSurfaceColor.subtleFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!action.isEnabled || activeTopic != nil)
        }
        .padding(AppSpacing.large)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.subtle, lineWidth: 1)
        }
    }

    private var totalAvailableCount: Int {
        appModel.sentenceStudyTopicSummaries.values.reduce(0) { $0 + $1.totalCount }
    }

    private var studyTopics: [SentenceStudyTopic] {
        var topics = appModel.sentenceStudyTopicSummaries.keys
            .filter { $0 != .favorites }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        topics.insert(.favorites, at: 0)
        return topics
    }

    private var topicDueCount: Int {
        appModel.sentenceStudyTopicSummaries.values.reduce(0) { $0 + $1.dueCount }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func action(for summary: SentenceStudyTopicSummary) -> (title: String, isEnabled: Bool) {
        if summary.dueCount > 0 {
            return (L10n.string("study.topic.action.start", "去学习"), true)
        }
        if summary.reviewableTodayCount > 0 {
            return (L10n.string("study.topic.action.review", "再学一遍"), true)
        }
        return (L10n.string("study.topic.action.empty", "暂无内容"), false)
    }

    @MainActor
    private func start(_ topic: SentenceStudyTopic) async {
        activeTopic = topic
        defer { activeTopic = nil }

        do {
            guard let session = try await appModel.loadSentenceStudyTopicSession(for: topic) else {
                errorMessage = L10n.string("study.topic.empty.action_hint", "这个主题暂时没有可学习的句子。")
                return
            }
            topicSession = session
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                : error.localizedDescription
        }
    }
}
