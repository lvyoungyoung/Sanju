import SwiftUI
import UIKit

struct SentenceStudySessionView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var activeQueue: [SentenceStudyQueueItem]
    @State private var currentIndex = 0
    @State private var isShowingCompletion = false
    @State private var isReviewingToday: Bool
    @State private var isPreparingReviewQueue = false
    @State private var reviewQueueErrorMessage: String?
    @State private var isShowingStudySettings = false

    init(queue: [SentenceStudyQueueItem], startsInReviewMode: Bool = false) {
        _activeQueue = State(initialValue: queue)
        _isReviewingToday = State(initialValue: startsInReviewMode)
    }

    private var currentItem: SentenceStudyQueueItem? {
        guard activeQueue.indices.contains(currentIndex) else { return nil }
        return activeQueue[currentIndex]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if isShowingCompletion {
                    SentenceStudyCompletionView(
                        todayCompletedCount: appModel.sentenceStudyTodayCount,
                        canReviewToday: appModel.hasSentenceStudyReviewContent || !activeQueue.isEmpty,
                        isPreparingReviewQueue: isPreparingReviewQueue,
                        reviewQueueErrorMessage: reviewQueueErrorMessage,
                        onReviewToday: restartTodayReview,
                        onClose: {
                            Task {
                                await appModel.finishSentenceStudySession()
                            }
                        }
                    )
                    .padding(.horizontal, AppSpacing.section)
                } else if let currentItem {
                    SentenceStudyQuestionView(
                        item: currentItem,
                        index: currentIndex + 1,
                        total: activeQueue.count,
                        recordsProgress: !isReviewingToday
                    ) {
                        isShowingStudySettings = false
                        if currentIndex < activeQueue.count - 1 {
                            currentIndex += 1
                        } else {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                isShowingCompletion = true
                            }
                        }
                    }
                    .id(currentItem.id)
                    .safeAreaInset(edge: .bottom) {
                        studySettingsButton
                    }
                } else {
                    EmptyStateView(
                        title: L10n.string("study.empty.title", "今天没有待学习句子"),
                        subtitle: L10n.string("study.empty.subtitle", "先回到收藏页挑几句想学的内容，再开始今天这一轮。")
                    )
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                HStack {
                    Button {
                        Task {
                            await appModel.finishSentenceStudySession()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: AppIconSize.regular, weight: .semibold))
                            .foregroundStyle(Color(red: 0.34, green: 0.27, blue: 0.23))
                            .frame(width: AppControlHeight.compact, height: AppControlHeight.compact)
                            .background(Color.white, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !isShowingCompletion, let currentItem {
                        Text(
                            isReviewingToday
                            ? L10n.string(
                                "study.progress.review",
                                "再练句子 %d/%d",
                                min(currentIndex + 1, activeQueue.count),
                                activeQueue.count
                            )
                            : L10n.string(
                                "study.progress.active",
                                "学习句子 %d/%d",
                                min(currentIndex + 1, activeQueue.count),
                                activeQueue.count
                            )
                        )
                            .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                            .foregroundStyle(Color(red: 0.34, green: 0.27, blue: 0.23))
                            .padding(.horizontal, AppControlPadding.regular)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.94), in: Capsule())
                            .id(currentItem.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .sheet(isPresented: $isShowingStudySettings) {
                StudySettingsSheet(
                    isAutoSpeakingEnabled: appModel.isAutoSpeakingSolvedSentenceEnabled,
                    onToggleAutoSpeaking: { isEnabled in
                        appModel.setAutoSpeakingSolvedSentenceEnabled(isEnabled)
                    }
                )
                .presentationDetents([.height(230)])
                .presentationBackground(Color(.systemGroupedBackground))
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var studySettingsButton: some View {
        HStack {
            Spacer()

            Button {
                isShowingStudySettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: AppIconSize.regular, weight: .semibold))
                    .foregroundStyle(Color(red: 0.91, green: 0.52, blue: 0.17))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.96), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(AppStroke.highlight, lineWidth: 1)
                    }
                    .appSurfaceShadow()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("study.settings.title", "学习设置"))

            Spacer()
        }
        .padding(.bottom, AppSpacing.medium)
    }

    private func restartTodayReview() {
        guard !isPreparingReviewQueue else { return }
        reviewQueueErrorMessage = nil

        if isReviewingToday {
            restartReview(with: activeQueue)
            return
        }

        isPreparingReviewQueue = true
        Task { @MainActor in
            do {
                let reviewQueue = try await appModel.loadSentenceStudyTodayReviewQueue()
                guard !reviewQueue.isEmpty else {
                    reviewQueueErrorMessage = L10n.string("study.error.review_queue_unavailable", "今天学过的句子暂时无法加载，请稍后再试。")
                    isPreparingReviewQueue = false
                    return
                }
                restartReview(with: reviewQueue)
            } catch {
                reviewQueueErrorMessage = L10n.string("study.error.review_queue_unavailable", "今天学过的句子暂时无法加载，请稍后再试。")
            }
            isPreparingReviewQueue = false
        }
    }

    private func restartReview(with queue: [SentenceStudyQueueItem]) {
        guard !queue.isEmpty else { return }
        isShowingStudySettings = false
        activeQueue = queue
        currentIndex = 0
        isReviewingToday = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            isShowingCompletion = false
        }
    }
}

private struct StudySettingsSheet: View {
    let isAutoSpeakingEnabled: Bool
    let onToggleAutoSpeaking: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text(L10n.string("study.settings.title", "学习设置"))
                .font(.system(size: AppFontSize.field, weight: .bold))
                .foregroundStyle(AppTextColor.title)

            Toggle(
                L10n.string("study.settings.auto_speak_completed_sentence", "填空完成后自动朗读句子"),
                isOn: Binding(
                    get: { isAutoSpeakingEnabled },
                    set: onToggleAutoSpeaking
                )
            )
            .font(.system(size: AppFontSize.body, weight: .medium))
            .foregroundStyle(AppTextColor.primary)
            .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
            .padding(AppSpacing.large)
            .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .appSurfaceShadow()
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.top, AppSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SentenceStudyQuestionView: View {
    @EnvironmentObject private var appModel: AppModel
    let item: SentenceStudyQueueItem
    let index: Int
    let total: Int
    let recordsProgress: Bool
    let onAdvance: () -> Void

    @State private var question: SentenceStudyQuestion
    @State private var filledBlankWordIDs: [UUID: UUID] = [:]
    @State private var activeBlankID: UUID?
    @State private var wrongBlankID: UUID?
    @State private var isSavingProgress = false
    @State private var didPersistProgress = false
    @State private var didAutoSpeak = false
    @State private var saveErrorMessage: String?

    init(
        item: SentenceStudyQueueItem,
        index: Int,
        total: Int,
        recordsProgress: Bool = true,
        onAdvance: @escaping () -> Void
    ) {
        self.item = item
        self.index = index
        self.total = total
        self.recordsProgress = recordsProgress
        self.onAdvance = onAdvance
        let question = SentenceStudyQuestion(item: item)
        _question = State(initialValue: question)
        _activeBlankID = State(initialValue: question.blankIDs.first)
    }

    private var image: Image? {
        guard let memory = appModel.memory(withID: item.memoryID),
              !memory.imageData.isEmpty,
              let uiImage = UIImage(data: memory.imageData) else {
            return nil
        }
        return Image(uiImage: uiImage)
    }

    private var remainingWords: [SentenceStudyWordBankItem] {
        question.wordBank.filter { !filledBlankWordIDs.values.contains($0.id) }
    }

    private var allBlanksFilled: Bool {
        filledBlankWordIDs.count == question.blankIDs.count
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppSpacing.large) {
                SentenceStudyPromptCard(
                    image: image,
                    chinese: item.chinese,
                    progressText: "\(index) / \(total)"
                )
                .transaction { transaction in
                    transaction.animation = nil
                }

                VStack(alignment: .leading, spacing: 18) {
                    StudyFlowLayout(horizontalSpacing: 8, verticalSpacing: 12) {
                        ForEach(question.tokens) { token in
                            if token.isBlank,
                               let blankID = token.blankID,
                               let matchingWord = question.wordItem(for: blankID) {
                                SentenceStudyBlankTokenView(
                                    token: token,
                                    width: question.blankWidth(for: matchingWord),
                                    filledWord: filledWord(for: blankID),
                                    isFocused: activeBlankID == blankID,
                                    isWrong: wrongBlankID == blankID
                                ) {
                                    activeBlankID = blankID
                                    if wrongBlankID != blankID {
                                        wrongBlankID = nil
                                    }
                                }
                            } else {
                                Text(token.displayText)
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(AppTextColor.title)
                            }
                        }
                    }

                    Divider()
                        .overlay(Color.black.opacity(0.05))

                    if !remainingWords.isEmpty {
                        StudyFlowLayout(horizontalSpacing: 10, verticalSpacing: 12) {
                            ForEach(remainingWords) { word in
                                SentenceStudyWordTagView(word: word.text)
                                    .onTapGesture {
                                        fillActiveBlank(with: word.id)
                                    }
                            }
                        }
                    }
                }
                .padding(AppSpacing.xLarge)
                .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
                .appCardShadow()

                if allBlanksFilled {
                    SentenceStudySolvedState(
                        isSavingProgress: isSavingProgress,
                        saveErrorMessage: saveErrorMessage,
                        onSpeak: {
                            appModel.speech.speak(item.english)
                        },
                        onRetrySync: {
                            submitSolvedSentenceIfNeeded(forceRetry: true)
                        },
                        onAdvance: onAdvance
                    )
                } else {
                    Text(L10n.string("study.question.hint", "点击对应的单词，填写到高亮的空格中。"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.black.opacity(0.46))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.section)
            .padding(.bottom, AppSpacing.xxxLarge)
        }
        .task(id: item.memoryID) {
            await appModel.ensureMemoryImageLoaded(memoryID: item.memoryID)
        }
        .onChange(of: filledBlankWordIDs.count) { _, newValue in
            guard newValue == question.blankIDs.count else { return }
            speakSolvedSentenceIfNeeded()
            submitSolvedSentenceIfNeeded(forceRetry: false)
        }
    }

    private func filledWord(for blankID: UUID) -> SentenceStudyWordBankItem? {
        guard let filledWordID = filledBlankWordIDs[blankID] else { return nil }
        return question.wordBank.first(where: { $0.id == filledWordID })
    }

    @discardableResult
    private func placeWord(_ wordID: UUID, into blankID: UUID) -> Bool {
        guard !allBlanksFilled,
              filledBlankWordIDs[blankID] == nil,
              let word = question.wordBank.first(where: { $0.id == wordID }) else {
            return false
        }

        guard question.isCorrectWord(word, for: blankID) else {
            wrongBlankID = blankID
            return false
        }

        filledBlankWordIDs[blankID] = wordID
        wrongBlankID = nil
        activeBlankID = nextUnfilledBlank(after: blankID)
        return true
    }

    private func fillActiveBlank(with wordID: UUID) {
        guard let activeBlankID else { return }
        _ = placeWord(wordID, into: activeBlankID)
    }

    private func speakSolvedSentenceIfNeeded() {
        guard !didAutoSpeak,
              appModel.isAutoSpeakingSolvedSentenceEnabled else { return }
        didAutoSpeak = true
        appModel.speech.speak(item.english)
    }

    private func nextUnfilledBlank(after blankID: UUID) -> UUID? {
        let remainingBlankIDs = question.blankIDs.filter { filledBlankWordIDs[$0] == nil && $0 != blankID }
        guard !remainingBlankIDs.isEmpty else { return nil }

        if let currentIndex = question.blankIDs.firstIndex(of: blankID) {
            for index in question.blankIDs.indices where index > currentIndex {
                let candidate = question.blankIDs[index]
                if filledBlankWordIDs[candidate] == nil && candidate != blankID {
                    return candidate
                }
            }
        }

        return remainingBlankIDs.first
    }

    private func submitSolvedSentenceIfNeeded(forceRetry: Bool) {
        guard recordsProgress else { return }
        guard allBlanksFilled else { return }
        guard forceRetry || (!didPersistProgress && !isSavingProgress) else { return }

        isSavingProgress = true
        saveErrorMessage = nil

        Task {
            do {
                _ = try await appModel.recordSentenceStudyCompletion(sentenceID: item.sentenceID)
                await MainActor.run {
                    didPersistProgress = true
                    isSavingProgress = false
                }
            } catch {
                await MainActor.run {
                    isSavingProgress = false
                    saveErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }
}

private struct SentenceStudyPromptCard: View {
    let image: Image?
    let chinese: String
    let progressText: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(Color(red: 0.96, green: 0.92, blue: 0.86))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: AppFontSize.panelTitle, weight: .medium))
                                .foregroundStyle(Color.black.opacity(0.18))
                        }
                }
            }
            .frame(width: 94, height: 94)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(chinese)
                    .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                    .foregroundStyle(AppTextColor.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.97, blue: 0.93),
                            Color(red: 0.98, green: 0.95, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .appSurfaceShadow()
    }
}

private struct SentenceStudySolvedState: View {
    let isSavingProgress: Bool
    let saveErrorMessage: String?
    let onSpeak: () -> Void
    let onRetrySync: () -> Void
    let onAdvance: () -> Void

    private var isRetrying: Bool {
        saveErrorMessage != nil
    }

    private var statusMessage: String? {
        saveErrorMessage
    }

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppFontSize.display, weight: .semibold))
                .foregroundStyle(Color(red: 0.23, green: 0.70, blue: 0.42))

            Text(L10n.string("study.solved.title", "填空完成"))
                .font(.system(size: AppFontSize.field, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)

            Group {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(isRetrying ? Color(red: 0.82, green: 0.28, blue: 0.22) : AppTextColor.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 20)

            HStack(spacing: AppSpacing.medium) {
                Button {
                    onSpeak()
                } label: {
                    Label(L10n.string("study.solved.speak", "朗读句子"), systemImage: "speaker.wave.2.fill")
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(Color(red: 0.91, green: 0.52, blue: 0.17))
                        .frame(maxWidth: .infinity)
                        .frame(height: AppControlHeight.prominent)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(Color(red: 0.99, green: 0.95, blue: 0.90))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    guard !isSavingProgress else { return }
                    if isRetrying {
                        onRetrySync()
                    } else {
                        onAdvance()
                    }
                } label: {
                    HStack(spacing: AppSpacing.small) {
                        if isSavingProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isRetrying ? L10n.string("study.solved.retry_sync", "重试同步") : L10n.string("study.solved.next", "下一句"))
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: AppControlHeight.prominent)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.98, green: 0.67, blue: 0.18),
                                        Color(red: 0.91, green: 0.52, blue: 0.17)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .opacity(isSavingProgress ? 0.96 : 1)
            }
        }
        .padding(AppSpacing.xLarge)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(Color.white)
        )
        .appCardShadow()
    }
}

private struct SentenceStudyCompletionView: View {
    @EnvironmentObject private var appModel: AppModel
    let todayCompletedCount: Int
    let canReviewToday: Bool
    let isPreparingReviewQueue: Bool
    let reviewQueueErrorMessage: String?
    let onReviewToday: () -> Void
    let onClose: () -> Void
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: AppSpacing.section) {
            SentenceStudyFireworksView(isAnimating: isAnimating)
                .padding(.top, 40)

            VStack(spacing: AppSpacing.medium) {
                Text(L10n.string("study.completion.title", "你已完成学习"))
                    .font(.system(size: AppFontSize.pageTitle, weight: .bold))
                    .foregroundStyle(AppTextColor.title)

                Text(L10n.string("study.completion.today_count", "今天已经学习了 %d 句", todayCompletedCount))
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(AppTextColor.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if todayCompletedCount >= SentenceStudyPolicy.dailyLimit {
                    Text(L10n.string("study.completion.daily_limit_hint", "今天已经学习了很多，休息一下吧"))
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(Color(red: 0.91, green: 0.52, blue: 0.17))
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: AppSpacing.medium) {
                if canReviewToday {
                    Button {
                        onReviewToday()
                    } label: {
                        HStack(spacing: AppSpacing.small) {
                            if isPreparingReviewQueue {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
                            }

                            Text(isPreparingReviewQueue ? L10n.string("study.completion.preparing_review", "正在准备...") : L10n.string("study.completion.review_again", "再学习一遍"))
                                .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 0.91, green: 0.52, blue: 0.17))
                        .frame(maxWidth: .infinity)
                        .frame(height: AppControlHeight.prominent)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(Color(red: 0.99, green: 0.95, blue: 0.90))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparingReviewQueue)
                }

                if let reviewQueueErrorMessage {
                    Text(reviewQueueErrorMessage)
                        .font(.system(size: AppFontSize.caption))
                        .foregroundStyle(Color.red.opacity(0.72))
                        .multilineTextAlignment(.center)
                }

                Button {
                    onClose()
                } label: {
                    Text(L10n.string("common.back", "返回"))
                        .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppControlHeight.prominent)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.98, green: 0.67, blue: 0.18),
                                            Color(red: 0.91, green: 0.52, blue: 0.17)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
            .padding(.horizontal, AppSpacing.section)

            Spacer(minLength: 0)

            learningReminderHint
                .padding(.horizontal, AppSpacing.small)
                .padding(.bottom, AppSpacing.section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, AppSpacing.xLarge)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }

    private var learningReminderHint: some View {
        Text(learningReminderHintText)
            .font(.system(size: AppFontSize.metadata, weight: .medium))
            .foregroundStyle(AppTextColor.tertiary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
    }

    private var learningReminderHintText: String {
        if appModel.isLearningReminderEnabled {
            return L10n.string(
                "study.reminder.enabled_hint",
                "你已开启定时提醒，将在每天%@提醒你学习",
                appModel.learningReminderDisplayText
            )
        }

        return L10n.string("study.reminder.disabled_hint", "你可以在设置中开启定时提醒，每天提醒你学习。")
    }
}

private struct SentenceStudyFireworksView: View {
    let isAnimating: Bool

    private let bursts: [(x: CGFloat, y: CGFloat, color: Color, delay: Double)] = [
        (0, 0, Color(red: 0.98, green: 0.67, blue: 0.18), 0.0),
        (-48, -28, Color(red: 0.95, green: 0.49, blue: 0.32), 0.2),
        (52, -22, Color(red: 0.96, green: 0.75, blue: 0.24), 0.35)
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1.00, green: 0.96, blue: 0.91))
                .frame(width: 148, height: 148)
                .scaleEffect(isAnimating ? 1.04 : 0.96)

            ForEach(Array(bursts.enumerated()), id: \.offset) { _, burst in
                FireworkBurst(color: burst.color, isAnimating: isAnimating)
                    .offset(x: burst.x, y: burst.y)
            }

            Image(systemName: "sparkles")
                .font(.system(size: AppFontSize.celebration, weight: .bold))
                .foregroundStyle(Color(red: 0.96, green: 0.60, blue: 0.14))
                .scaleEffect(isAnimating ? 1.06 : 0.94)
        }
        .frame(height: 180)
    }
}

private struct FireworkBurst: View {
    let color: Color
    let isAnimating: Bool

    private let angles = stride(from: 0.0, to: 360.0, by: 45.0).map { $0 }

    var body: some View {
        ZStack {
            ForEach(angles, id: \.self) { angle in
                Capsule(style: .continuous)
                    .fill(color.opacity(0.9))
                    .frame(width: 7, height: 26)
                    .offset(y: isAnimating ? -26 : -14)
                    .rotationEffect(.degrees(angle))
            }

            Circle()
                .fill(color)
                .frame(width: isAnimating ? 9 : 6, height: isAnimating ? 9 : 6)
        }
        .opacity(isAnimating ? 1 : 0.7)
        .scaleEffect(isAnimating ? 1 : 0.82)
    }
}
