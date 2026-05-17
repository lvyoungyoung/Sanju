import CryptoKit
import SwiftUI
import UIKit

struct MemoriesView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var memoryPendingDeletion: MemoryEntry?
    @State private var isPerformingInitialLoad = false
    @State private var hasCompletedInitialLoad = false
    @State private var visibleMemoryCount = 20
    @State private var isLoadingMoreMemories = false
    @State private var memorySections: [MemorySection] = []

    private let columns = [
        GridItem(.flexible(), spacing: AppSpacing.xLarge),
        GridItem(.flexible(), spacing: AppSpacing.xLarge)
    ]
    private let memoryPageSize = 20
    private let loadMoreFooterThreshold: CGFloat = 120

    private var heroTitleFontSize: CGFloat {
        horizontalSizeClass == .compact ? 23 : 26
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: AppSpacing.large) {
                    memoriesHero

                    if appModel.isSyncingPendingCloudChanges, appModel.pendingCloudSyncTotalCount > 0 {
                        PendingCloudSyncProgressCard(
                            completedCount: appModel.pendingCloudSyncCompletedCount,
                            totalCount: appModel.pendingCloudSyncTotalCount,
                            pendingGuestMemoryCount: appModel.pendingGuestMemoryCount,
                            pendingFavoriteChangeCount: appModel.pendingFavoriteChangeCount,
                            pendingMemoryDeletionCount: appModel.pendingMemoryDeletionCount
                        )
                    }

                    if appModel.memories.isEmpty {
                        if appModel.isSyncingRemoteMemories || shouldShowInitialLoadingState {
                            SyncLoadingState(
                                title: L10n.string("memories.syncing.title", "正在同步回忆..."),
                                subtitle: L10n.string("memories.syncing.subtitle", "马上就好，正在更新你的回忆内容")
                            )
                            .padding(.top, 80)
                        } else {
                            EmptyStateView(
                                title: L10n.string("memories.empty.title", "还没有回忆"),
                                subtitle: L10n.string("memories.empty.subtitle", "在“新的”里上传第一张照片，生成你的第一组三句话。")
                            )
                            .padding(.top, 36)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: AppSpacing.xxLarge) {
                            ForEach(memorySections) { section in
                                VStack(alignment: .leading, spacing: AppSpacing.large) {
                                    Text(section.title)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.primary)

                                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppSpacing.xLarge) {
                                        ForEach(section.items) { item in
                                            NavigationLink(value: item.memory.id) {
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
                .padding(.horizontal, AppSpacing.xLarge)
                .padding(.top, AppSpacing.xLarge)
                .padding(.bottom, AppSpacing.xxxLarge)
            }
            .coordinateSpace(name: MemoryScrollMetrics.coordinateSpaceName)
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .task {
                rebuildMemorySections(using: currentVisibleMemories(from: appModel.memories))
                await performInitialLoadIfNeeded()
            }
            .onChange(of: appModel.memories) { _, newMemories in
                updateVisibleMemoryCount(using: newMemories)
                rebuildMemorySections(using: currentVisibleMemories(from: newMemories))
            }
            .onPreferenceChange(MemoryFooterMinYPreferenceKey.self) { footerMinY in
                guard hasMoreMemoriesToDisplay else { return }
                guard footerMinY < proxy.size.height + loadMoreFooterThreshold else { return }
                Task {
                    await loadMoreMemoriesIfNeeded()
                }
            }
            .refreshable {
                guard appModel.isSignedIn else { return }
                await appModel.refreshRemoteContent()
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

    private var memoriesHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.98, blue: 0.94),
                            Color(red: 0.94, green: 0.97, blue: 0.99)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: AppSpacing.large) {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    Text(L10n.string("memories.hero.eyebrow", "回忆"))
                        .font(.system(size: AppFontSize.sectionLabel, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))

                    Text(L10n.string("memories.hero.title", "把你记录过的画面留成一页一页可回看的学习素材"))
                        .font(.system(size: heroTitleFontSize, weight: .bold))
                        .foregroundStyle(AppHeroTextColor.title)
                        .lineSpacing(4)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 110)
            }
            .padding(AppSpacing.xLarge)

            VStack(spacing: 6) {
                Text("\(appModel.recordedMemoriesCount)")
                    .font(.system(size: AppFontSize.heroStat, weight: .bold))
                    .foregroundStyle(AppHeroTextColor.title)

                Text(L10n.string("memories.hero.count_label", "已记录"))
                    .font(.system(size: AppFontSize.badge, weight: .medium))
                    .foregroundStyle(AppHeroTextColor.tertiary)
            }
            .frame(width: 92, height: 92)
            .background(Color.white.opacity(0.74), in: Circle())
            .padding(.top, AppSpacing.xLarge)
            .padding(.trailing, AppSpacing.xLarge)
        }
        .appHeroShadow()
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
        !hasCompletedInitialLoad && isPerformingInitialLoad
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
        visibleMemoryCount < appModel.memories.count
    }

    @MainActor
    private func performInitialLoadIfNeeded() async {
        guard !hasCompletedInitialLoad, !isPerformingInitialLoad else { return }

        if !appModel.memories.isEmpty {
            hasCompletedInitialLoad = true
            return
        }

        guard appModel.isSignedIn else {
            hasCompletedInitialLoad = true
            return
        }

        isPerformingInitialLoad = true
        await appModel.refreshRemoteContent()
        isPerformingInitialLoad = false
        hasCompletedInitialLoad = true
    }

    @MainActor
    private func loadMoreMemoriesIfNeeded(currentMemoryID: UUID) async {
        guard !isLoadingMoreMemories else { return }
        guard currentMemoryID == currentVisibleMemories(from: appModel.memories).last?.id else { return }
        await loadMoreMemoriesIfNeeded()
    }

    @MainActor
    private func loadMoreMemoriesIfNeeded() async {
        guard !isLoadingMoreMemories else { return }
        guard hasMoreMemoriesToDisplay else { return }

        isLoadingMoreMemories = true
        let nextVisibleCount = min(visibleMemoryCount + memoryPageSize, appModel.memories.count)
        visibleMemoryCount = nextVisibleCount
        rebuildMemorySections(using: currentVisibleMemories(from: appModel.memories))
        await appModel.loadMoreRemoteMemoriesIfNeeded(through: nextVisibleCount)
        isLoadingMoreMemories = false
    }
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
                .tint(Color(red: 0.98, green: 0.65, blue: 0.00))
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
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
    let memory: MemoryEntry
    let animationDelay: Double
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
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            .opacity(hasAppeared ? 1 : 0.01)
            .scaleEffect(hasAppeared ? 1 : 0.97)
            .offset(y: hasAppeared ? 0 : 8)
            .onAppear {
                loadImageIfNeeded()
                loadRemoteImageIfNeeded()
                guard !hasAppeared else { return }
                withAnimation(.easeOut(duration: 0.28).delay(animationDelay)) {
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
        RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
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
