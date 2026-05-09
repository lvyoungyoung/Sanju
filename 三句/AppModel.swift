//
//  AppModel.swift
//  三句
//
//  Created by Codex.
//

import Combine
import Foundation

struct SentenceRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let english: String
    let chinese: String
    var isFavorite: Bool

    init(id: UUID = UUID(), english: String, chinese: String, isFavorite: Bool = false) {
        self.id = id
        self.english = english
        self.chinese = chinese
        self.isFavorite = isFavorite
    }
}

struct MemoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let imageData: Data
    var remoteImagePath: String?
    var syncedToAccount: Bool
    var sentences: [SentenceRecord]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        imageData: Data,
        remoteImagePath: String? = nil,
        syncedToAccount: Bool = false,
        sentences: [SentenceRecord]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.imageData = imageData
        self.remoteImagePath = remoteImagePath
        self.syncedToAccount = syncedToAccount
        self.sentences = sentences
    }
}

struct UserProfile: Codable, Hashable {
    var appleUserID: String
    var nickname: String
    var email: String?
}

struct FavoriteSentence: Identifiable, Hashable {
    let memoryID: UUID
    let sentence: SentenceRecord

    var id: UUID { sentence.id }
}

enum SentenceStudyResult: String, Codable, Hashable {
    case correct
    case incorrect
}

enum SentenceStudyPolicy {
    static let dailyLimit = 30
}

struct SentenceStudyProgress: Identifiable, Codable, Hashable {
    let id: UUID
    let sentenceID: UUID
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: SentenceStudyResult?
    let lastStudiedAt: Date?
    let nextReviewAt: Date
}

struct LocalSentenceStudyProgress: Identifiable, Codable, Hashable {
    let id: UUID
    let sentenceID: UUID
    var learningStep: Int
    var masteredReviewCount: Int
    var correctCount: Int
    var wrongCount: Int
    var lastResult: SentenceStudyResult?
    var lastStudiedAt: Date?
    var lastStudiedDay: Date?
    var nextReviewDay: Date

    init(
        id: UUID = UUID(),
        sentenceID: UUID,
        learningStep: Int = 0,
        masteredReviewCount: Int = 0,
        correctCount: Int = 0,
        wrongCount: Int = 0,
        lastResult: SentenceStudyResult? = nil,
        lastStudiedAt: Date? = nil,
        lastStudiedDay: Date? = nil,
        nextReviewDay: Date = .now
    ) {
        self.id = id
        self.sentenceID = sentenceID
        self.learningStep = learningStep
        self.masteredReviewCount = masteredReviewCount
        self.correctCount = correctCount
        self.wrongCount = wrongCount
        self.lastResult = lastResult
        self.lastStudiedAt = lastStudiedAt
        self.lastStudiedDay = lastStudiedDay
        self.nextReviewDay = nextReviewDay
    }
}

struct SentenceStudyQueueItem: Identifiable, Hashable {
    let sentenceID: UUID
    let memoryID: UUID
    let english: String
    let chinese: String
    let imagePath: String
    let createdAt: Date
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: SentenceStudyResult?
    let nextReviewAt: Date?

    var id: UUID { sentenceID }
}

struct PendingMemoryImageUpload: Codable, Hashable {
    let memoryID: UUID
    let remoteImagePath: String
}

struct PendingGeneratedMemoryImage: Codable, Hashable {
    let startedAt: Date
    let previousMemoryIDs: [UUID]
    let guestJobID: String?
    let imageData: Data
}

struct PendingFavoriteChange: Codable, Hashable {
    let sentenceID: UUID
    let isFavorite: Bool
}

struct PendingMemoryDeletion: Codable, Hashable {
    let memoryID: UUID
    let remoteImagePath: String?
}

struct PendingGuestCreditMigration: Codable, Hashable {
    let accountUserID: String
    let guestUserID: String
    let guestRefreshToken: String
}

enum AppTab: Hashable {
    case newLearning
    case memories
    case favorites
    case profile
}

enum EnglishLevel: String, CaseIterable, Codable, Identifiable {
    case simple = "简单"
    case intermediate = "中等"
    case advanced = "高级"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .simple:
            return L10n.string("english_level.simple", "初级")
        case .intermediate:
            return L10n.string("english_level.intermediate", "中级")
        case .advanced:
            return L10n.string("english_level.advanced", "高级")
        }
    }
}

enum LanguageStyle: String, CaseIterable, Codable, Identifiable {
    case plain = "平铺直叙"
    case lyrical = "抒情优美"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .plain:
            return L10n.string("language_style.plain", "平铺直叙")
        case .lyrical:
            return L10n.string("language_style.lyrical", "抒情优雅")
        }
    }
}

enum AppStorageKey {
    static let guestMemoriesUserID = "guest"
    static let installMarker = "sanju.installMarker"
    static let initialCreditsGrantMarker = "sanju.initialCreditsGrantMarker"
    static let profile = "sanju.profile"
    static let memories = "sanju.memories"
    static let memoriesUserID = "sanju.memoriesUserID"
    static let pendingMemoryImageUploads = "sanju.pendingMemoryImageUploads"
    static let pendingGeneratedMemoryImage = "sanju.pendingGeneratedMemoryImage"
    static let pendingGuestMemoryMigrationQueue = "sanju.pendingGuestMemoryMigrationQueue"
    static let pendingFavoriteChanges = "sanju.pendingFavoriteChanges"
    static let pendingMemoryDeletions = "sanju.pendingMemoryDeletions"
    static let pendingGuestCreditMergeLegacy = "sanju.pendingGuestCreditMerge"
    static let pendingGuestCreditMigration = "sanju.pendingGuestCreditMigration"
    static let preserveLocalGuestCreditsAgainstAnonymousProfile = "sanju.preserveLocalGuestCreditsAgainstAnonymousProfile"
    static let pendingLocalAccountTransition = "sanju.pendingLocalAccountTransition"
    static let generationAttemptTimestamps = "sanju.generationAttemptTimestamps"
    static let passwordResetAttemptTimestamps = "sanju.passwordResetAttemptTimestamps"
    static let emailSignInFailureTimestamps = "sanju.emailSignInFailureTimestamps"
    static let preferenceChangeTimestamps = "sanju.preferenceChangeTimestamps"
    static let preferenceChangeBlockedUntil = "sanju.preferenceChangeBlockedUntil"
    static let remainingCredits = "sanju.remainingCredits"
    static let remainingCreditsOwnerID = "sanju.remainingCreditsOwnerID"
    static let englishLevel = "sanju.englishLevel"
    static let languageStyle = "sanju.languageStyle"
    static let learningReminderEnabled = "sanju.learningReminderEnabled"
    static let learningReminderHour = "sanju.learningReminderHour"
    static let learningReminderMinute = "sanju.learningReminderMinute"
    static let localSentenceStudyProgress = "sanju.localSentenceStudyProgress"
    static let supabaseSession = "sanju.supabaseSession"
    static let processedPurchaseTransactions = "sanju.processedPurchaseTransactions"
}

enum KimiServiceError: LocalizedError {
    case invalidImage
    case noCredits
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return L10n.string("generation_error.invalid_image", "图片处理失败，请重新选择一张图片。")
        case .noCredits:
            return L10n.string("generation_error.no_credits", "可用生成次数不足，请先购买。")
        case .sessionUnavailable:
            return L10n.string("generation_error.session_unavailable", "暂时无法建立访客会话，请检查网络后重试。")
        }
    }
}

enum EmailAuthenticationOutcome {
    case signedIn
    case requiresEmailConfirmation
    case failed
}

enum PasswordResetOutcome {
    case updated
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profile: UserProfile?
    @Published var memories: [MemoryEntry] = []
    @Published var remainingCredits: Int = 5
    @Published var englishLevel: EnglishLevel = .simple
    @Published var languageStyle: LanguageStyle = .plain
    @Published var isLearningReminderEnabled = false
    @Published var learningReminderHour = 20
    @Published var learningReminderMinute = 30
    @Published var authErrorMessage: String?
    @Published var authFlowMessage: String?
    @Published var credentialWarningMessage: String?
    @Published var isAuthenticating = false
    @Published var isRequestingPasswordReset = false
    @Published var isUpdatingPassword = false
    @Published var passwordResetErrorMessage: String?
    @Published var isShowingSignInSheet = false
    @Published var isGeneratingMemory = false
    @Published var isNetworkAvailable = true
    @Published var purchaseErrorMessage: String?
    @Published var isStartingPurchase = false
    @Published var isCompletingPurchase = false
    @Published var isRestoringAuthenticatedSession = false
    @Published var isSyncingRemoteMemories = false
    @Published var isHydratingRemoteMemoryImages = false
    @Published var isDeletingAccount = false
    @Published var isSyncingPendingCloudChanges = false
    @Published var pendingCloudSyncCompletedCount = 0
    @Published var pendingCloudSyncTotalCount = 0
    @Published var recordedMemoriesCount = 0
    @Published var favoriteSentencesCount = 0
    @Published var sentenceStudyDueCount = 0
    @Published var sentenceStudyTodayCount = 0
    @Published var sentenceStudyReviewableTodayCount = 0
    @Published var sentenceStudyQueue: [SentenceStudyQueueItem] = []
    @Published var isLoadingSentenceStudyQueue = false
    @Published var isShowingSentenceStudySession = false
    @Published var isRepeatingSentenceStudyQueue = false
    @Published var sentenceStudyErrorMessage: String?
    @Published var draftLearningImageData: Data?
    @Published var draftLearningItemIdentifier: String?
    @Published var draftGeneratedMemory: MemoryEntry?
    @Published var draftGeneratedMemoryID: UUID?
    @Published var selectedTab: AppTab = .newLearning
    @Published var memoriesNavigationPath: [UUID] = []

    let speech = SpeechService()
    let purchaseManager = PurchaseManager()
    let supabaseService: SupabaseServicing
    let cloudSyncManager = CloudSyncManager()
    let defaults = UserDefaults.standard
    let localRateLimiter = LocalRateLimiter()
    let networkStatusMonitor = NetworkStatusMonitor()
    var supabaseSession: SupabaseSession?
    var processedPurchaseTransactionIDs: Set<String> = []
    var processingPurchaseTransactionIDs: Set<String> = []
    var isRecoveringPendingPurchases = false
    var pendingMemoryImageUploads: [PendingMemoryImageUpload] = []
    var isRetryingPendingMemoryImageUploads = false
    var pendingGeneratedMemoryImage: PendingGeneratedMemoryImage?
    var pendingGuestMemoryMigrationQueue: [MemoryEntry] = []
    var localSentenceStudyProgress: [UUID: LocalSentenceStudyProgress] = [:]
    var pendingFavoriteChanges: [PendingFavoriteChange] = []
    var pendingMemoryDeletions: [PendingMemoryDeletion] = []
    var pendingGuestCreditMigration: PendingGuestCreditMigration?
    var postSignInSyncTask: Task<Void, Never>?
    var foregroundSyncTask: Task<Void, Never>?
    var sessionRestoreTask: Task<Void, Never>?
    var remoteContentRefreshTask: Task<Void, Never>?
    var remoteMemoriesSyncTask: Task<Void, Never>?
    var remoteMemoryImageHydrationTask: Task<Void, Never>?
    var cachedMemoryImageHydrationTask: Task<Void, Never>?
    var memoryWidgetSnapshotUpdateTask: Task<Void, Never>?
    var preferenceSyncTask: Task<Void, Never>?
    var memoryImageLoadTaskIDs: Set<UUID> = []
    var remoteMemoryImageHydrationTargetCount = 0
    var hasStartedObservingPurchaseTransactions = false

    init(supabaseService: SupabaseServicing = SupabaseService()) {
        self.supabaseService = supabaseService
#if DEBUG
        // resetInitialCreditsGrantForDebug()
#endif
        handleFreshInstallIfNeeded()
        loadPersistedState()
        if loadStoredSession()?.isAnonymous == false {
            isRestoringAuthenticatedSession = true
        }
        startNetworkMonitoring()
        Task {
            await ensureRemoteSessionRestoreCompleted()
            startObservingPurchaseTransactionsIfNeeded()
            await processUnfinishedPurchases()
        }
    }

    var hasAuthenticatedSession: Bool {
        supabaseSession?.isAnonymous == false
    }

    var isSignedIn: Bool {
        hasAuthenticatedSession && profile != nil
    }

    var hasRemoteSession: Bool {
        supabaseSession != nil
    }

    var isUsingAnonymousSession: Bool {
        supabaseSession?.isAnonymous ?? false
    }

    var canPresentAuthenticatedUI: Bool {
        isSignedIn
    }

    var shouldShowAuthenticatedRestoreUI: Bool {
        isRestoringAuthenticatedSession && profile == nil && !hasAuthenticatedSession
    }

    var hasPurchaseHistory: Bool {
        !processedPurchaseTransactionIDs.isEmpty
    }

    var isPurchaseSessionPreparing: Bool {
        isRestoringAuthenticatedSession
    }

    var hasActiveGenerationTask: Bool {
        if isGeneratingMemory { return true }
        guard let pendingGeneratedMemoryImage else { return false }
        return !isPendingGeneratedRecoveryExpired(pendingGeneratedMemoryImage)
    }

    var favorites: [FavoriteSentence] {
        memories
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { memory in
                memory.sentences
                    .filter(\.isFavorite)
                    .map { FavoriteSentence(memoryID: memory.id, sentence: $0) }
            }
    }

    var pendingGuestMemoryCount: Int {
        memories.filter { isMemoryContentComplete($0) && !$0.syncedToAccount }.count
    }

    var pendingFavoriteChangeCount: Int {
        pendingFavoriteChanges.count
    }

    var canStartSentenceStudy: Bool {
        (hasNewSentenceStudyContent || hasSentenceStudyReviewContent)
            && !isLoadingSentenceStudyQueue
    }

    var hasReachedSentenceStudyDailyLimit: Bool {
        sentenceStudyTodayCount >= SentenceStudyPolicy.dailyLimit
    }

    var hasNewSentenceStudyContent: Bool {
        sentenceStudyDueCount > 0
    }

    var hasSentenceStudyReviewContent: Bool {
        sentenceStudyReviewableTodayCount > 0
    }

    var pendingMemoryDeletionCount: Int {
        pendingMemoryDeletions.count
    }

    deinit {
        postSignInSyncTask?.cancel()
        foregroundSyncTask?.cancel()
        sessionRestoreTask?.cancel()
        remoteContentRefreshTask?.cancel()
        remoteMemoriesSyncTask?.cancel()
        remoteMemoryImageHydrationTask?.cancel()
        cachedMemoryImageHydrationTask?.cancel()
        memoryWidgetSnapshotUpdateTask?.cancel()
        preferenceSyncTask?.cancel()
        networkStatusMonitor.cancel()
    }

    func syncOnForegroundIfNeeded() {
        guard foregroundSyncTask == nil else { return }

        foregroundSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.foregroundSyncTask = nil }

            await self.retryPendingPurchasesIfNeeded()
            guard !Task.isCancelled else { return }

            await self.retryPendingMemoryImageUploadsIfNeeded()
            guard !Task.isCancelled else { return }

            if self.hasAuthenticatedSession {
                await self.refreshRemoteContent()
            }
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "sanju" else { return }
        if isNewLearningURL(url) {
            openNewLearningFromExternalLink()
            return
        }
        guard let memoryID = memoryID(from: url) else { return }
        openMemoryFromExternalLink(memoryID)
    }

    func openNewLearningFromExternalLink() {
        selectedTab = .newLearning
        memoriesNavigationPath = []
    }

    func openMemoryFromExternalLink(_ memoryID: UUID) {
        selectedTab = .memories
        memoriesNavigationPath = []

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.memoriesNavigationPath = [memoryID]
        }
    }

    private func memoryID(from url: URL) -> UUID? {
        if url.host?.lowercased() == "memory" {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return UUID(uuidString: path)
        }

        let components = url.pathComponents.filter { $0 != "/" }
        if components.count == 2, components[0].lowercased() == "memory" {
            return UUID(uuidString: components[1])
        }

        return nil
    }

    private func isNewLearningURL(_ url: URL) -> Bool {
        if url.host?.lowercased() == "new" {
            return true
        }

        let components = url.pathComponents.filter { $0 != "/" }
        return components.count == 1 && components[0].lowercased() == "new"
    }

}
