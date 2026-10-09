import CryptoKit
import SwiftUI
import UIKit

struct MemoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var memoryPendingDeletion: MemoryEntry?
    @State private var isPerformingInitialLoad = false
    @State private var hasCompletedInitialLoad = false
    @State private var visibleMemoryCount = 20
    @State private var isLoadingMoreMemories = false
    @State private var memorySections: [MemorySection] = []
    @State private var pageTitleOriginY: CGFloat?
    @State private var pageTitleMinY: CGFloat = 0
    @State private var albumFlipSession: AlbumFlipPresentation?
    @State private var browseMode: MemoryBrowseMode = .time
    @State private var photoCollection: MemoryPhotoCollection?
    let topicID: String?

    init(topicID: String? = nil) {
        self.topicID = topicID
    }

    private let columns = [
        GridItem(.flexible(), spacing: AppSpacing.medium),
        GridItem(.flexible(), spacing: AppSpacing.medium)
    ]
    private let memoryPageSize = 20
    private let loadMoreFooterThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: AppSpacing.large) {
                    if topicID == nil {
                        pageHeader
                        MemoryBrowseTabs(mode: $browseMode)
                    } else {
                        Text(MemoryPhotoCollection.photoCountTitle(scopedMemories.count))
                            .font(.subheadline)
                            .foregroundStyle(AppTextColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if appModel.isSyncingPendingCloudChanges, appModel.pendingCloudSyncTotalCount > 0 {
                        PendingCloudSyncProgressCard(
                            completedCount: appModel.pendingCloudSyncCompletedCount,
                            totalCount: appModel.pendingCloudSyncTotalCount,
                            pendingGuestMemoryCount: appModel.pendingGuestMemoryCount,
                            pendingFavoriteChangeCount: appModel.pendingFavoriteChangeCount,
                            pendingMemoryDeletionCount: appModel.pendingMemoryDeletionCount
                        )
                    }

                    if contentState != .content {
                        if contentState == .loading {
                            SyncLoadingState(
                                title: L10n.string("memories.syncing.title", "正在同步回忆..."),
                                subtitle: L10n.string("memories.syncing.subtitle", "马上就好，正在更新你的回忆内容")
                            )
                            .padding(.top, 80)
                        } else if contentState == .failed {
                            ContentLoadFailureState {
                                Task { await appModel.refreshRemoteContent() }
                            }
                            .padding(.top, 36)
                        } else {
                            if topicID != nil {
                                ContentUnavailableView(
                                    L10n.string("memories.topic.empty", "这个主题下暂时没有照片"),
                                    systemImage: "photo.on.rectangle"
                                )
                                .padding(.top, 36)
                            } else {
                                AddPhotoEmptyState(destination: .memories) {
                                    appModel.selectedTab = .newLearning
                                }
                                .padding(.top, 36)
                            }
                        }
                    } else if !isShowingPhotos {
                        LazyVGrid(columns: columns, spacing: AppSpacing.medium) {
                            ForEach(collection.topics) { topic in
                                NavigationLink(value: MemoryNavigationRoute.photoTopic(topic.id)) {
                                    MemoryPhotoTopicCard(topic: topic)
                                }
                                .buttonStyle(StudioPressStyle())
                            }
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: AppSpacing.xxLarge) {
                            ForEach(memorySections) { section in
                                VStack(alignment: .leading, spacing: AppSpacing.large) {
                                    Text(section.title)
                                        .font(.system(.subheadline, weight: .medium))
                                        .foregroundStyle(AppTextColor.secondary)

                                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.medium) {
                                        ForEach(section.items) { item in
                                            NavigationLink(value: MemoryNavigationRoute.memory(item.memory.id)) {
                                                MemoryThumbnailTile(
                                                    memory: item.memory,
                                                    animationDelay: item.animationDelay
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .onAppear {
                                                Task {
                                                    await loadMoreMemoriesIfNeeded(currentMemoryID: item.memory.id)
                                                }
                                            }
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    memoryPendingDeletion = item.memory
                                                } label: {
                                                    Label(L10n.string("common.delete", "删除"), systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            footerHint
                        }
                        .padding(.top, 4)
                    }
                    }
                    .padding(.horizontal, AppSpacing.section)
                    .padding(.top, AppSpacing.xLarge)
                    .padding(.bottom, AppSpacing.xxxLarge)
                }
                .coordinateSpace(name: MemoryScrollMetrics.coordinateSpaceName)
                .refreshable {
                    guard appModel.isSignedIn else { return }
                    await appModel.refreshRemoteContent()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isShowingPhotos && hasFlippableSentences {
                        Button {
                            albumFlipSession = AlbumFlipPresentation(
                                items: collection.flipItems(in: topicID),
                                ownerID: appModel.albumFlipOwnerID
                            )
                        } label: {
                            Label(L10n.string("album_flip.open", "翻一翻"), systemImage: "rectangle.on.rectangle.angled")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(AppPalette.onAccent)
                                .padding(.horizontal, 26)
                                .frame(minHeight: 52)
                                .background(AppPalette.accent, in: Capsule())
                                .appAccentShadow(AppPalette.accent)
                        }
                        .buttonStyle(StudioPressStyle())
                        .accessibilityHint(L10n.string("album_flip.open_hint", "随机翻看照片，听一句英语"))
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                        .background {
                            LinearGradient(colors: [AppSurfaceColor.page.opacity(0), AppSurfaceColor.page], startPoint: .top, endPoint: .bottom)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .background(AppSurfaceColor.page)
            .fullScreenCover(item: $albumFlipSession) { session in
                AlbumFlipView(items: session.items, ownerID: session.ownerID)
                    .environmentObject(appModel)
            }
            .navigationTitle(topicTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(topicID == nil ? .hidden : .visible, for: .navigationBar)
            .task(id: appModel.isRestoringAuthenticatedSession ? nil : appModel.supabaseSession?.userID) {
                rebuildPhotoContent(using: appModel.memories)
                guard !appModel.isRestoringAuthenticatedSession else { return }
                hasCompletedInitialLoad = false
                isPerformingInitialLoad = false
                await performInitialLoadIfNeeded()
            }
            .onChange(of: appModel.memories) { _, newMemories in
                rebuildPhotoContent(using: newMemories)
            }
            .onChange(of: appModel.albumFlipOwnerID) { _, _ in
                albumFlipSession = nil
                memoryPendingDeletion = nil
                visibleMemoryCount = memoryPageSize
                browseMode = .time
                rebuildPhotoContent(using: appModel.memories)
            }
            .onPreferenceChange(MemoryFooterMinYPreferenceKey.self) { footerMinY in
                guard isShowingPhotos else { return }
                guard hasMoreMemoriesToDisplay else { return }
                guard footerMinY < proxy.size.height + loadMoreFooterThreshold else { return }
                Task {
                    await loadMoreMemoriesIfNeeded()
                }
            }
            .onPreferenceChange(MemoryPageTitleMinYPreferenceKey.self) { minY in
                if pageTitleOriginY == nil {
                    pageTitleOriginY = minY
                }
                pageTitleMinY = minY
            }
            .alert(L10n.string("memory.delete.alert_title", "删除这条回忆？"), isPresented: memoryDeleteAlertBinding) {
                Button(L10n.string("common.delete", "删除"), role: .destructive) {
                    if let memoryID = memoryPendingDeletion?.id {
                        appModel.deleteMemory(memoryID: memoryID)
                    }
                    memoryPendingDeletion = nil
                }
                Button(L10n.string("common.cancel", "取消"), role: .cancel) {
                    memoryPendingDeletion = nil
                }
            } message: {
                Text(L10n.string("memory.delete.alert_message", "删除后，这张图片和对应的三句话都会被移除。"))
            }
        }
    }

    private var pageHeader: some View {
        Text(L10n.string("memories.page_title", "回忆"))
            .font(AppTypography.pageTitle)
            .foregroundStyle(AppTextColor.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(pageTitleOpacity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MemoryPageTitleMinYPreferenceKey.self,
                        value: proxy.frame(in: .named(MemoryScrollMetrics.coordinateSpaceName)).minY
                    )
                }
            }
    }

    private var hasFlippableSentences: Bool {
        scopedMemories.contains { memory in
            memory.sentences.contains { !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private var collection: MemoryPhotoCollection {
        photoCollection ?? MemoryPhotoCollection(memories: appModel.memories)
    }

    private var scopedMemories: [MemoryEntry] { collection.memories(in: topicID) }
    private var isShowingPhotos: Bool { topicID != nil || browseMode == .time }
    private var topicTitle: String {
        guard let topicID else { return L10n.string("memories.page_title", "回忆") }
        return MemoryPhotoCategory.category(for: topicID)?.title ?? L10n.string("memories.topic.uncategorized", "未分类")
    }

    private var pageTitleOpacity: Double {
        guard let pageTitleOriginY else { return 1 }
        let fadeDistance: CGFloat = 64
        return min(1, max(0, Double((pageTitleMinY - pageTitleOriginY + fadeDistance) / fadeDistance)))
    }

    private var memoryDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { memoryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    memoryPendingDeletion = nil
                }
            }
        )
    }

    private func makeSections(from memories: [MemoryEntry]) -> [MemorySection] {
        let calendar = Calendar.current
        let sortedMemories = memories.sorted { $0.createdAt > $1.createdAt }
        let animationDelaysByID = Dictionary(
            uniqueKeysWithValues: sortedMemories.enumerated().map { index, memory in
                (memory.id, min(Double(index) * 0.04, 0.2))
            }
        )
        let grouped = Dictionary(grouping: sortedMemories) { memory in
            calendar.startOfDay(for: memory.createdAt)
        }

        return grouped
            .keys
            .sorted(by: >)
            .map { date in
                let sectionMemories = grouped[date, default: []].sorted { $0.createdAt > $1.createdAt }
                return MemorySection(
                    date: date,
                    items: sectionMemories.map { memory in
                        let animationDelay = animationDelaysByID[memory.id] ?? 0
                        return MemorySectionItem(memory: memory, animationDelay: animationDelay)
                    }
                )
            }
    }

    private func rebuildMemorySections(using memories: [MemoryEntry]) {
        memorySections = makeSections(from: memories)
    }

    private func rebuildPhotoContent(using memories: [MemoryEntry]) {
        photoCollection = MemoryPhotoCollection(memories: memories)
        updateVisibleMemoryCount(using: scopedMemories)
        rebuildMemorySections(using: currentVisibleMemories(from: scopedMemories))
    }

    private func currentVisibleMemories(from memories: [MemoryEntry]) -> [MemoryEntry] {
        Array(memories.prefix(visibleMemoryCount))
    }

    private func updateVisibleMemoryCount(using memories: [MemoryEntry]) {
        guard !memories.isEmpty else {
            visibleMemoryCount = memoryPageSize
            return
        }

        let minimumVisibleCount = min(memoryPageSize, memories.count)
        visibleMemoryCount = min(
            max(visibleMemoryCount, minimumVisibleCount),
            memories.count
        )
    }

    private var shouldShowInitialLoadingState: Bool {
        !hasCompletedInitialLoad && (isPerformingInitialLoad || appModel.isSignedIn)
    }

    private var contentState: PhotoContentState {
        .resolve(
            hasContent: !scopedMemories.isEmpty,
            isLoading: appModel.isRestoringAuthenticatedSession || appModel.isSyncingRemoteMemories || shouldShowInitialLoadingState || appModel.memoryLoadState == .loading,
            hasError: appModel.memoryLoadState == .failed
        )
    }

    private var shouldShowSyncingFooterHint: Bool {
        appModel.isSyncingRemoteMemories || appModel.isHydratingRemoteMemoryImages || isLoadingMoreMemories
    }

    private var footerHint: some View {
        Group {
            if hasMoreMemoriesToDisplay {
                VStack(spacing: 6) {
                    Text(
                        isLoadingMoreMemories
                        ? L10n.string("memories.load_more.loading", "正在加载更多回忆...")
                        : L10n.string("memories.load_more.prompt", "继续下滑以加载更多回忆")
                    )
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: MemoryFooterMinYPreferenceKey.self,
                                value: proxy.frame(in: .named(MemoryScrollMetrics.coordinateSpaceName)).minY
                            )
                    }
                    .frame(height: 1)
                    .id("memory-load-more-\(visibleMemoryCount)")
                    .onAppear {
                        Task {
                            await loadMoreMemoriesIfNeeded()
                        }
                    }
                }
                .padding(.vertical, 6)
            } else {
                ContentFooterHint(isLoading: shouldShowSyncingFooterHint)
            }
        }
    }

    private var hasMoreMemoriesToDisplay: Bool {
        visibleMemoryCount < scopedMemories.count
    }

    @MainActor
    private func performInitialLoadIfNeeded() async {
        guard !hasCompletedInitialLoad, !isPerformingInitialLoad else { return }

        if !appModel.memories.isEmpty {
            hasCompletedInitialLoad = true
            return
        }

        guard appModel.isSignedIn || appModel.loadStoredSession()?.isAnonymous == false else {
            hasCompletedInitialLoad = true
            return
        }

        isPerformingInitialLoad = true
        await appModel.refreshRemoteContent()
        guard !Task.isCancelled else { return }
        isPerformingInitialLoad = false
        hasCompletedInitialLoad = true
    }

    @MainActor
    private func loadMoreMemoriesIfNeeded(currentMemoryID: UUID) async {
        guard !isLoadingMoreMemories else { return }
        guard currentMemoryID == currentVisibleMemories(from: scopedMemories).last?.id else { return }
        await loadMoreMemoriesIfNeeded()
    }

    @MainActor
    private func loadMoreMemoriesIfNeeded() async {
        guard !isLoadingMoreMemories else { return }
        guard isShowingPhotos else { return }
        guard hasMoreMemoriesToDisplay else { return }

        isLoadingMoreMemories = true
        let nextVisibleCount = min(visibleMemoryCount + memoryPageSize, scopedMemories.count)
        visibleMemoryCount = nextVisibleCount
        let newlyVisibleMemories = currentVisibleMemories(from: scopedMemories)
        rebuildMemorySections(using: newlyVisibleMemories)

        // Topic photos can be scattered across the full library. Load only visible thumbnails.
        if topicID == nil {
            let remoteLoadTarget = newlyVisibleMemories.compactMap { memory in
                appModel.memories.firstIndex(where: { $0.id == memory.id }).map { $0 + 1 }
            }.max() ?? nextVisibleCount
            await appModel.loadMoreRemoteMemoriesIfNeeded(through: remoteLoadTarget)
        }
        isLoadingMoreMemories = false
    }
}

struct MemoryBrowseTabs: View {
    @Binding var mode: MemoryBrowseMode

    var body: some View {
        PreferenceSegmentedControl(
            titles: MemoryBrowseMode.allCases.map(\.title),
            selection: Binding(
                get: { mode.rawValue },
                set: { mode = MemoryBrowseMode(rawValue: $0) ?? .time }
            ),
            accessibilityTitle: L10n.string("memories.browse.label", "回忆查看方式")
        )
        .frame(height: 44)
    }
}

private struct MemoryPhotoTopicCard: View {
    let topic: MemoryPhotoTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cover = topic.cover {
                MemoryThumbnailTile(memory: cover, animationDelay: 0, cornerRadius: 10)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
                    .lineLimit(2, reservesSpace: true)
                Text(MemoryPhotoCollection.photoCountTitle(topic.memories.count))
                    .font(.subheadline)
                    .foregroundStyle(AppTextColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
        .padding(8)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct AlbumFlipPresentation: Identifiable {
    let id = UUID()
    let items: [AlbumFlipItem]
    let ownerID: String
}

private enum MemoryScrollMetrics {
    static let coordinateSpaceName = "memoriesScroll"
}

private struct MemoryFooterMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MemoryPageTitleMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PendingCloudSyncProgressCard: View {
    let completedCount: Int
    let totalCount: Int
    let pendingGuestMemoryCount: Int
    let pendingFavoriteChangeCount: Int
    let pendingMemoryDeletionCount: Int

    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("memories.pending_sync.title", "正在同步本地改动到云端"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text("\(completedCount)/\(totalCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTextColor.tertiary)
            }

            ProgressView(value: progress)
                .tint(AppPalette.accent)
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous))
        .appSurfaceShadow()
    }
}

private struct MemorySection: Identifiable {
    let date: Date
    let items: [MemorySectionItem]

    var id: Date { date }

    var title: String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter
    }()
}

private struct MemorySectionItem: Identifiable {
    let memory: MemoryEntry
    let animationDelay: Double

    var id: UUID { memory.id }
}

private struct MemoryThumbnailTile: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let memory: MemoryEntry
    let animationDelay: Double
    var cornerRadius: CGFloat = AppCornerRadius.card
    @State private var hasAppeared = false
    @State private var cachedImage: UIImage?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var remoteImageLoadTask: Task<Void, Never>?
    @State private var imageLoadToken = UUID()

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cachedImage {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    MemoryThumbnailSkeleton()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(hasAppeared ? 1 : 0.01)
            .scaleEffect(hasAppeared ? 1 : 0.97)
            .offset(y: hasAppeared ? 0 : 8)
            .onAppear {
                loadImageIfNeeded()
                loadRemoteImageIfNeeded()
                guard !hasAppeared else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28).delay(animationDelay)) {
                    hasAppeared = true
                }
            }
            .onChange(of: memory.imageData) { _, _ in
                imageLoadTask?.cancel()
                cachedImage = nil
                loadImageIfNeeded()
                loadRemoteImageIfNeeded()
            }
            .onDisappear {
                imageLoadTask?.cancel()
                imageLoadTask = nil
                remoteImageLoadTask?.cancel()
                remoteImageLoadTask = nil
            }
    }

    private func loadImageIfNeeded() {
        guard !memory.imageData.isEmpty else {
            imageLoadTask?.cancel()
            imageLoadTask = nil
            return
        }

        imageLoadTask?.cancel()

        let currentToken = UUID()
        imageLoadToken = currentToken
        let memoryID = memory.id
        let imageData = memory.imageData

        imageLoadTask = Task {
            let result = await Task.detached(priority: .utility) { () -> (String, UIImage)? in
                let cacheKey = MemoryImageCache.cacheKey(for: memoryID, imageData: imageData)

                if let image = MemoryImageCache.shared.object(forKey: cacheKey as NSString) {
                    return (cacheKey, image)
                }

                guard let image = UIImage(data: imageData) else { return nil }
                MemoryImageCache.shared.setObject(image, forKey: cacheKey as NSString)
                return (cacheKey, image)
            }.value

            guard !Task.isCancelled, imageLoadToken == currentToken else { return }
            cachedImage = result?.1
            imageLoadTask = nil
        }
    }

    private func loadRemoteImageIfNeeded() {
        guard memory.imageData.isEmpty, memory.remoteImagePath != nil else {
            remoteImageLoadTask?.cancel()
            remoteImageLoadTask = nil
            return
        }
        guard remoteImageLoadTask == nil else { return }

        let memoryID = memory.id
        remoteImageLoadTask = Task {
            await appModel.ensureMemoryImageLoaded(memoryID: memoryID)
            guard !Task.isCancelled else { return }
            remoteImageLoadTask = nil
        }
    }
}

private enum MemoryImageCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        return cache
    }()

    nonisolated static func cacheKey(for memoryID: UUID, imageData: Data) -> String {
        let digest = SHA256.hash(data: imageData)
        let digestString = digest.map { String(format: "%02x", $0) }.joined()
        return "\(memoryID.uuidString)-\(digestString)"
    }
}

private struct MemoryThumbnailSkeleton: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        RoundedRectangle(cornerRadius: AppCornerRadius.card, style: .continuous)
            .fill(Color.gray.opacity(0.14))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.28),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.38)
                    .offset(x: proxy.size.width * phase)
                }
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.35
                }
            }
    }
}
