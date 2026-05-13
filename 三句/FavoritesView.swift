import SwiftUI

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
                            title: L10n.string("favorites.syncing.title", "正在同步收藏..."),
                            subtitle: L10n.string("favorites.syncing.subtitle", "马上就好，正在更新你的收藏内容")
                        )
                        .padding(.top, 80)
                    } else {
                        EmptyStateView(
                            title: L10n.string("favorites.empty.title", "还没有收藏"),
                            subtitle: L10n.string("favorites.empty.subtitle", "在生成结果里点亮右侧星标，你最常用、最喜欢的句子都会留在这里。"),
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
                                        Label(L10n.string("favorites.action.unfavorite", "取消收藏"), systemImage: "star.slash")
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
        .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: sentenceStudyErrorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
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
                    Text(L10n.string("favorites.hero.eyebrow", "收藏"))
                        .font(.system(size: AppFontSize.sectionLabel, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))

                    Text(L10n.string("favorites.hero.title", "把你想反复练习的句子留在一个地方"))
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

                    Text(L10n.string("favorites.hero.count_label", "已收藏"))
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
                    label: L10n.string("study.metric.due_today", "今日待学")
                )

                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1, height: 34)

                StudyMetricView(
                    value: "\(appModel.sentenceStudyTodayCount)",
                    label: L10n.string("study.metric.studied_today", "今日已学")
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
    @State private var horizontalOffset: CGFloat = 0

    private let unfavoriteSwipeThreshold: CGFloat = 96
    private let maxSwipeOffset: CGFloat = 124

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(Color(red: 0.96, green: 0.42, blue: 0.28))

            HStack(spacing: AppSpacing.small) {
                Image(systemName: "star.slash")
                    .font(.system(size: AppIconSize.regular, weight: .semibold))

                Text(L10n.string("favorites.action.unfavorite", "取消收藏"))
                    .font(.system(size: AppFontSize.caption, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.trailing, AppSpacing.xLarge)
            .opacity(unfavoriteActionOpacity)

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
                }
            }
            .padding(AppSpacing.xLarge)
            .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .offset(x: horizontalOffset)
            .gesture(unfavoriteSwipeGesture)
        }
        .appCardShadow()
    }

    private var unfavoriteSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                guard value.translation.width < 0 else {
                    horizontalOffset = 0
                    return
                }
                horizontalOffset = max(value.translation.width, -maxSwipeOffset)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        horizontalOffset = 0
                    }
                    return
                }

                if value.translation.width <= -unfavoriteSwipeThreshold {
                    withAnimation(.easeOut(duration: 0.18)) {
                        horizontalOffset = -maxSwipeOffset
                    }
                    appModel.deleteFavorite(sentenceID: item.favorite.id)
                } else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        horizontalOffset = 0
                    }
                }
            }
    }

    private var unfavoriteActionOpacity: Double {
        let progress = min(max(-horizontalOffset / unfavoriteSwipeThreshold, 0), 1)
        return 0.35 + (progress * 0.65)
    }

    static func formattedDate(for date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()
}
