import SwiftUI
import UIKit

struct FavoritesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var favoriteItems: [FavoriteSentenceListItem] = []

    private var heroTitleFontSize: CGFloat {
        horizontalSizeClass == .compact ? 24 : 27
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppSpacing.large) {
                favoritesHero

                if !favoriteItems.isEmpty {
                    floatingStudyBar
                }

                if favoriteItems.isEmpty {
                    if appModel.isSyncingRemoteMemories {
                        SyncLoadingState(
                            title: "正在同步收藏...",
                            subtitle: "马上就好，正在更新你的收藏内容"
                        )
                        .padding(.top, 80)
                    } else {
                        EmptyStateView(
                            title: "还没有收藏",
                            subtitle: "在生成结果里点亮右侧星标，你最常用、最喜欢的句子都会留在这里。",
                            systemImage: "star"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                    }
                } else {
                    LazyVStack(spacing: AppSpacing.medium) {
                        ForEach(favoriteItems) { item in
                            FavoriteSentenceCard(item: item)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        appModel.deleteFavorite(sentenceID: item.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }

                        ContentFooterHint(isLoading: appModel.isSyncingRemoteMemories)
                            .padding(.top, 10)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .task {
            rebuildFavoriteItems(using: appModel.memories)
            await appModel.refreshSentenceStudyDueCount()
        }
        .onChange(of: appModel.memories) { _, newMemories in
            rebuildFavoriteItems(using: newMemories)
        }
        .onChange(of: appModel.favoriteSentencesCount) { _, _ in
            Task {
                await appModel.refreshSentenceStudyDueCount()
            }
        }
        .refreshable {
            guard appModel.isSignedIn else { return }
            await appModel.refreshRemoteContent()
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .alert("学习提醒", isPresented: sentenceStudyErrorAlertBinding) {
            Button("知道了", role: .cancel) {
                appModel.sentenceStudyErrorMessage = nil
            }
        } message: {
            Text(appModel.sentenceStudyErrorMessage ?? "")
        }
        .fullScreenCover(isPresented: $appModel.isShowingSentenceStudySession) {
            SentenceStudySessionView(
                queue: appModel.sentenceStudyQueue,
                startsInReviewMode: appModel.isRepeatingSentenceStudyQueue
            )
                .environmentObject(appModel)
        }
    }

    private var sentenceStudyErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.sentenceStudyErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    appModel.sentenceStudyErrorMessage = nil
                }
            }
        )
    }

    private func rebuildFavoriteItems(using memories: [MemoryEntry]) {
        favoriteItems = memories
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { memory in
                let createdDateText = FavoriteSentenceCard.formattedDate(for: memory.createdAt)
                return memory.sentences
                    .filter(\.isFavorite)
                    .map { sentence in
                        FavoriteSentenceListItem(
                            favorite: FavoriteSentence(memoryID: memory.id, sentence: sentence),
                            createdDateText: createdDateText
                        )
                    }
            }
    }

    private var favoritesHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.95, blue: 0.92),
                            Color(red: 0.98, green: 0.93, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: AppSpacing.large) {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    Text("收藏")
                        .font(.system(size: AppFontSize.sectionLabel, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))

                    Text("把你想反复练习的句子留在一个地方")
                        .font(.system(size: heroTitleFontSize, weight: .bold))
                        .foregroundStyle(AppTextColor.title)
                        .lineSpacing(4)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 112)
            }
            .padding(AppSpacing.xLarge)

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 94, height: 94)

                VStack(spacing: AppSpacing.xSmall) {
                    Text("\(appModel.favoriteSentencesCount)")
                        .font(.system(size: AppFontSize.heroStat, weight: .bold))
                        .foregroundStyle(Color(red: 0.34, green: 0.27, blue: 0.23))

                    Text("已收藏")
                        .font(.system(size: AppFontSize.badge, weight: .medium))
                        .foregroundStyle(AppTextColor.tertiary)
                }
            }
            .padding(.top, AppSpacing.xLarge)
            .padding(.trailing, AppSpacing.xLarge)
        }
        .appHeroShadow()
    }

    private var floatingStudyBar: some View {
        HStack(spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.medium) {
                StudyMetricView(
                    value: "\(appModel.sentenceStudyDueCount)",
                    label: "今日待学"
                )

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 34)

                StudyMetricView(
                    value: "\(appModel.sentenceStudyTodayCount)",
                    label: "今日已学"
                )
            }
            .padding(.leading, 4)

            Spacer()

            Button {
                Task {
                    await appModel.startSentenceStudy()
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    if appModel.isLoadingSentenceStudyQueue {
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
                                colors: appModel.canStartSentenceStudy ? [
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
            .disabled(!appModel.canStartSentenceStudy)
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.94),
                            Color(red: 1.00, green: 0.96, blue: 0.91).opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.highlight, lineWidth: 1)
        )
        .appCardShadow()
    }

    private var studyButtonTitle: String {
        if appModel.isLoadingSentenceStudyQueue {
            return "正在准备学习内容..."
        }
        if appModel.hasNewSentenceStudyContent {
            return "开始学习"
        }
        if appModel.hasSentenceStudyReviewContent {
            return "再学一遍"
        }
        return "今天学完了"
    }
}

private struct StudyMetricView: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(value)
                .font(.system(size: AppFontSize.stat, weight: .bold))
                .foregroundStyle(Color(red: 0.34, green: 0.27, blue: 0.23))
                .monospacedDigit()

            Text(label)
                .font(.system(size: AppFontSize.caption, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.42))
        }
        .frame(minWidth: 54, alignment: .leading)
    }
}

private struct FavoriteSentenceListItem: Identifiable, Hashable {
    let favorite: FavoriteSentence
    let createdDateText: String?

    var id: UUID { favorite.id }
}

private struct FavoriteSentenceCard: View {
    @EnvironmentObject private var appModel: AppModel
    let item: FavoriteSentenceListItem

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack(alignment: .top) {
                Text(item.favorite.sentence.english)
                    .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    appModel.speech.speak(item.favorite.sentence.english)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                        .frame(width: AppControlHeight.compact, height: AppControlHeight.compact)
                        .background(Color(red: 0.99, green: 0.95, blue: 0.90), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Text(item.favorite.sentence.chinese)
                .font(.system(size: AppFontSize.sectionLabel))
                .foregroundStyle(AppTextColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if let createdDateText = item.createdDateText {
                    Label(createdDateText, systemImage: "calendar")
                        .font(.system(size: AppFontSize.caption, weight: .medium))
                        .foregroundStyle(AppTextColor.tertiary)
                }

                Spacer()

                Button {
                    appModel.deleteFavorite(sentenceID: item.favorite.id)
                } label: {
                    Text("取消收藏")
                        .font(.system(size: AppFontSize.caption, weight: .semibold))
                        .foregroundStyle(Color(red: 0.91, green: 0.46, blue: 0.24))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AppSpacing.xLarge)
        .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardShadow()
    }

    static func formattedDate(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

private struct SentenceStudySessionView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var activeQueue: [SentenceStudyQueueItem]
    @State private var currentIndex = 0
    @State private var isShowingCompletion = false
    @State private var isReviewingToday: Bool
    @State private var isPreparingReviewQueue = false
    @State private var reviewQueueErrorMessage: String?

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
                        if currentIndex < activeQueue.count - 1 {
                            currentIndex += 1
                        } else {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                isShowingCompletion = true
                            }
                        }
                    }
                    .id(currentItem.id)
                } else {
                    EmptyStateView(
                        title: "今天没有待学习句子",
                        subtitle: "先回到收藏页挑几句想学的内容，再开始今天这一轮。"
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
                            Text("\(isReviewingToday ? "再练句子" : "学习句子") \(min(currentIndex + 1, activeQueue.count))/\(activeQueue.count)")
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
        }
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
                    reviewQueueErrorMessage = "今天学过的句子暂时无法加载，请稍后再试。"
                    isPreparingReviewQueue = false
                    return
                }
                restartReview(with: reviewQueue)
            } catch {
                reviewQueueErrorMessage = "今天学过的句子暂时无法加载，请稍后再试。"
            }
            isPreparingReviewQueue = false
        }
    }

    private func restartReview(with queue: [SentenceStudyQueueItem]) {
        guard !queue.isEmpty else { return }
        activeQueue = queue
        currentIndex = 0
        isReviewingToday = true
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            isShowingCompletion = false
        }
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
                    Text("点击对应的单词，填写到高亮的空格中。")
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

            Text("填空完成")
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
                    Label("朗读句子", systemImage: "speaker.wave.2.fill")
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
                        Text(isRetrying ? "重试同步" : "下一句")
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
                Text("你已完成学习")
                    .font(.system(size: AppFontSize.pageTitle, weight: .bold))
                    .foregroundStyle(AppTextColor.title)

                Text("今天已经学习了 \(todayCompletedCount) 句")
                    .font(.system(size: AppFontSize.body))
                    .foregroundStyle(AppTextColor.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if todayCompletedCount >= SentenceStudyPolicy.dailyLimit {
                    Text("今天已经学习了很多，休息一下吧")
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

                            Text(isPreparingReviewQueue ? "正在准备..." : "再学习一遍")
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
                    Text("返回")
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
            return "你已开启定时提醒，将在每天\(appModel.learningReminderDisplayText)提醒你学习"
        }

        return "你可以在设置中开启定时提醒，每天提醒你学习。"
    }
}

struct LearningReminderSetupCard: View {
    @Binding var reminderTime: Date
    let isEnabled: Bool
    let isSaving: Bool
    let statusMessage: String?
    let statusIsError: Bool
    let onSave: () -> Void
    let onDisable: () -> Void
    let onEditTime: () -> Void

    private var reminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { isOn in
                if isOn {
                    onSave()
                } else {
                    onDisable()
                }
            }
        )
    }

    private var reminderTimeText: String {
        Self.timeFormatter.string(from: reminderTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.medium) {
                Toggle("", isOn: reminderEnabledBinding)
                    .labelsHidden()
                    .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
                    .disabled(isSaving)

                Spacer(minLength: 0)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.91, green: 0.52, blue: 0.17))
                } else if isEnabled {
                    Button(action: onEditTime) {
                        Text(reminderTimeText)
                            .font(.system(size: 17, weight: .semibold))
                            .monospacedDigit()
                        .foregroundStyle(Color(red: 0.74, green: 0.39, blue: 0.10))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(red: 1.00, green: 0.92, blue: 0.82))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: AppFontSize.caption))
                    .foregroundStyle(statusIsError ? Color.red.opacity(0.75) : Color(red: 0.35, green: 0.48, blue: 0.28))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
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

private struct SentenceStudyQuestion {
    let item: SentenceStudyQueueItem
    let tokens: [SentenceStudyToken]
    let wordBank: [SentenceStudyWordBankItem]
    let blankIDs: [UUID]

    init(item: SentenceStudyQueueItem) {
        self.item = item

        let parts = item.english
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)

        let parsedWords = parts.enumerated().map { index, part in
            SentenceStudyParsedWord(tokenIndex: index, raw: part)
        }

        let blankIndices = SentenceStudyQuestion.selectedBlankIndices(from: parsedWords)
        let blankWords = blankIndices.map { index in
            SentenceStudyWordBankItem(
                id: UUID(),
                blankID: UUID(),
                tokenIndex: index,
                text: parsedWords[index].core
            )
        }

        let wordMap = Dictionary(uniqueKeysWithValues: blankWords.map { ($0.tokenIndex, $0) })

        self.tokens = parsedWords.map { parsedWord in
            if let blankWord = wordMap[parsedWord.tokenIndex] {
                return SentenceStudyToken(
                    id: UUID(),
                    tokenIndex: parsedWord.tokenIndex,
                    prefix: parsedWord.prefix,
                    answer: parsedWord.core,
                    suffix: parsedWord.suffix,
                    blankID: blankWord.blankID,
                    correctWordID: blankWord.id
                )
            }

            return SentenceStudyToken(
                id: UUID(),
                tokenIndex: parsedWord.tokenIndex,
                prefix: parsedWord.prefix,
                answer: parsedWord.core,
                suffix: parsedWord.suffix,
                blankID: nil,
                correctWordID: nil
            )
        }

        self.wordBank = blankWords.shuffled()
        self.blankIDs = blankWords.map(\.blankID)
    }

    func wordItem(for blankID: UUID) -> SentenceStudyWordBankItem? {
        wordBank.first(where: { $0.blankID == blankID })
    }

    func isCorrectWord(_ word: SentenceStudyWordBankItem, for blankID: UUID) -> Bool {
        guard let expectedWord = wordItem(for: blankID) else { return false }
        return word.text == expectedWord.text
    }

    func blankWidth(for word: SentenceStudyWordBankItem) -> CGFloat {
        max(66, CGFloat(word.text.count) * 16 + 22)
    }

    private static func selectedBlankIndices(from words: [SentenceStudyParsedWord]) -> [Int] {
        let alphaWords = words.filter(\.isAlphabetic)
        guard !alphaWords.isEmpty else { return [] }

        let desiredCount: Int
        switch alphaWords.count {
        case 0:
            desiredCount = 0
        case 1...2:
            desiredCount = alphaWords.count
        case 3...7:
            desiredCount = 3
        case 8...11:
            desiredCount = 4
        default:
            desiredCount = 5
        }

        let preferred = alphaWords.filter(\.isPreferredBlankCandidate).map(\.tokenIndex)
        let fallback = alphaWords
            .filter { !preferred.contains($0.tokenIndex) }
            .map(\.tokenIndex)

        var selected = randomizedDistributedSelection(from: preferred, count: desiredCount)
        if selected.count < desiredCount {
            let excluded = Set(selected)
            let remainingFallback = fallback.filter { !excluded.contains($0) }
            selected.append(contentsOf: randomizedDistributedSelection(from: remainingFallback, count: desiredCount - selected.count))
        }

        return selected.sorted()
    }

    private static func randomizedDistributedSelection(from candidates: [Int], count: Int) -> [Int] {
        guard count > 0, !candidates.isEmpty else { return [] }
        if candidates.count <= count {
            return candidates
        }

        let bucketCount = min(count, candidates.count)
        var selected: [Int] = []
        var usedCandidates = Set<Int>()

        for bucketIndex in 0..<bucketCount {
            let lowerBound = bucketIndex * candidates.count / bucketCount
            let upperBound = ((bucketIndex + 1) * candidates.count / bucketCount) - 1
            let bucketCandidates = candidates[lowerBound...upperBound]
                .filter { !usedCandidates.contains($0) }

            if let candidate = bucketCandidates.randomElement() {
                selected.append(candidate)
                usedCandidates.insert(candidate)
            }
        }

        if selected.count < count {
            let remaining = candidates
                .filter { !usedCandidates.contains($0) }
                .shuffled()
                .prefix(count - selected.count)
            selected.append(contentsOf: remaining)
        }

        return selected.sorted()
    }
}

private struct SentenceStudyParsedWord {
    let tokenIndex: Int
    let raw: String
    let prefix: String
    let core: String
    let suffix: String

    init(tokenIndex: Int, raw: String) {
        self.tokenIndex = tokenIndex
        self.raw = raw

        let characters = Array(raw)
        let allowed = Self.allowedCharacters

        guard let start = characters.firstIndex(where: { allowed.contains($0.unicodeScalars.first!) }),
              let end = characters.lastIndex(where: { allowed.contains($0.unicodeScalars.first!) }),
              start <= end else {
            prefix = ""
            core = raw
            suffix = ""
            return
        }

        prefix = String(characters[..<start])
        core = String(characters[start...end])
        suffix = String(characters[(end + 1)...])
    }

    var isAlphabetic: Bool {
        core.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    var isPreferredBlankCandidate: Bool {
        let lowercased = core.lowercased()
        return isAlphabetic &&
            core.count >= 4 &&
            !SentenceStudyParsedWord.stopWords.contains(lowercased)
    }

    private static let allowedCharacters: CharacterSet = {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
    }()

    private static let stopWords: Set<String> = [
        "a", "am", "an", "and", "are", "as", "at", "be", "been", "being",
        "but", "by", "for", "from", "had", "has", "have", "he", "her", "his",
        "i", "in", "is", "it", "its", "me", "my", "of", "on", "or", "our",
        "she", "so", "that", "the", "their", "them", "there", "they", "this",
        "to", "up", "us", "very", "was", "we", "were", "with", "you", "your"
    ]
}

private struct SentenceStudyToken: Identifiable {
    let id: UUID
    let tokenIndex: Int
    let prefix: String
    let answer: String
    let suffix: String
    let blankID: UUID?
    let correctWordID: UUID?

    var isBlank: Bool {
        blankID != nil
    }

    var displayText: String {
        prefix + answer + suffix
    }
}

private struct SentenceStudyWordBankItem: Identifiable, Hashable {
    let id: UUID
    let blankID: UUID
    let tokenIndex: Int
    let text: String
}

private struct SentenceStudyBlankTokenView: View {
    let token: SentenceStudyToken
    let width: CGFloat
    let filledWord: SentenceStudyWordBankItem?
    let isFocused: Bool
    let isWrong: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if !token.prefix.isEmpty {
                Text(token.prefix)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.27, blue: 0.29))
            }

            Button(action: onTap) {
                Text(filledWord?.text ?? " ")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(filledWord == nil ? Color.clear : Color(red: 0.23, green: 0.45, blue: 0.29))
                    .frame(width: width, height: 32)
                    .background(blankBackground)
                    .overlay(blankOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            if !token.suffix.isEmpty {
                Text(token.suffix)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.28, green: 0.27, blue: 0.29))
            }
        }
    }

    private var blankBackground: some ShapeStyle {
        if filledWord != nil {
            return AnyShapeStyle(
                Color(red: 0.84, green: 0.95, blue: 0.85)
            )
        }

        if isWrong {
            return AnyShapeStyle(Color(red: 0.98, green: 0.84, blue: 0.84))
        }

        if isFocused {
            return AnyShapeStyle(Color(red: 1.00, green: 0.94, blue: 0.86))
        }

        return AnyShapeStyle(Color(red: 0.98, green: 0.96, blue: 0.94))
    }

    private var blankOverlay: some View {
        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
            .stroke(
                filledWord != nil
                ? Color.clear
                : isFocused
                    ? Color(red: 0.95, green: 0.61, blue: 0.15)
                    : isWrong
                        ? Color(red: 0.90, green: 0.31, blue: 0.28)
                        : Color(red: 0.88, green: 0.82, blue: 0.75),
                style: StrokeStyle(
                    lineWidth: 1.5,
                    dash: filledWord == nil ? [6, 4] : []
                )
            )
    }
}

private struct SentenceStudyWordTagView: View {
    let word: String

    var body: some View {
        Text(word)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(red: 0.35, green: 0.28, blue: 0.24))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(Color.white)
            )
            .overlay(
                Capsule()
                    .stroke(AppStroke.soft, lineWidth: 1.2)
            )
            .appSurfaceShadow()
    }
}

private struct StudyFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let containerWidth = proposal.width ?? UIScreen.main.bounds.width - 40
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }

        return CGSize(width: containerWidth, height: currentY + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
