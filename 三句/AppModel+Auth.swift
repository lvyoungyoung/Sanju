import Foundation

extension AppModel {
    private static let guestCreditRecoveryWarningMessages: Set<String> = [
        "登录成功，但访客可用次数仍在恢复中。请保持网络连接后重新打开应用。",
        "访客可用次数仍在恢复中，请保持网络连接后稍后再试。"
    ]
    private static let interruptedSignInRecoveryMessage = "上次登录未完成，请重新登录。"

    private var initialInstallCredits: Int { 5 }

    private var shouldPreserveRestoredGuestCreditsAgainstAnonymousProfile: Bool {
        defaults.bool(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
            && localCreditsBelongToGuest
            && remainingCredits > initialInstallCredits
    }

    fileprivate struct PreSignInGuestState {
        let pendingMemoryDeletions: [PendingMemoryDeletion]
    }

    private struct PreparedGuestCreditMigration {
        let guestSession: SupabaseSession
    }

    private enum GuestCreditPreparationError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "暂时无法安全迁移访客可用次数，请稍后在网络稳定时重试登录。"
        }
    }

    private func authDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[AuthFlow] \(message())")
        #endif
    }

    private func pendingCloudSyncDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[PendingCloudSync] \(message())")
        #endif
    }

    private var currentNetworkDebugDescription: String {
        networkStatusMonitor.currentDebugDescription
    }

    func handleFreshInstallIfNeeded() {
        guard defaults.bool(forKey: AppStorageKey.installMarker) == false else { return }

        KeychainStorage.remove(for: AppStorageKey.supabaseSession)
        KeychainStorage.remove(for: AppStorageKey.pendingGuestCreditMigration)
        defaults.removeObject(forKey: AppStorageKey.pendingGuestCreditMergeLegacy)
        if KeychainStorage.get(for: AppStorageKey.initialCreditsGrantMarker) == nil {
            remainingCredits = initialInstallCredits
            KeychainStorage.set(Data("granted".utf8), for: AppStorageKey.initialCreditsGrantMarker)
        } else {
            remainingCredits = 0
        }
        persistCredits()
        defaults.set(true, forKey: AppStorageKey.installMarker)
    }

    func handleEmailAuthentication(
        email: String,
        password: String,
        nickname: String?,
        shouldCreateAccount: Bool
    ) async -> EmailAuthenticationOutcome {
        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNickname = nickname.map(NicknameValidator.normalize)

        guard !normalizedEmail.isEmpty else {
            authErrorMessage = "请输入邮箱地址。"
            return .failed
        }

        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            authErrorMessage = "请输入正确的邮箱地址。"
            return .failed
        }

        guard !trimmedPassword.isEmpty else {
            authErrorMessage = "请输入密码。"
            return .failed
        }

        if shouldCreateAccount {
            do {
                _ = try NicknameValidator.validate(normalizedNickname ?? "")
            } catch {
                authErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .failed
            }
        }

        if shouldCreateAccount && trimmedPassword.count < 6 {
            authErrorMessage = "密码长度不足，请至少输入 6 位。"
            return .failed
        }

        if !shouldCreateAccount {
            do {
                try assertEmailSignInAllowed()
            } catch {
                authErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return .failed
            }
        }

        if hasAuthenticatedSession && profile == nil {
            revertIncompleteAuthenticatedRestoreToGuest()
        }

        guard isNetworkAvailable else {
            authDebugLog("Email auth blocked before request :: network unavailable :: \(currentNetworkDebugDescription)")
            authErrorMessage = "当前网络不可用，请连接网络后再登录。"
            return .failed
        }

        if !hasAuthenticatedSession {
            prepareGuestMemoriesForAuthenticatedFlowIfNeeded()
        }

        isAuthenticating = true
        authErrorMessage = nil
        authFlowMessage = nil
        credentialWarningMessage = nil
        let guestSessionToRestore = supabaseSession?.isAnonymous == true ? supabaseSession : nil

        do {
            let session: SupabaseSession
            if shouldCreateAccount {
                let validatedNickname = try NicknameValidator.validate(normalizedNickname ?? "")
                switch try await supabaseService.signUpWithEmail(
                    email: normalizedEmail,
                    password: trimmedPassword,
                    nickname: validatedNickname
                ) {
                case .session(let signedUpSession):
                    session = signedUpSession
                case .requiresEmailConfirmation:
                    authFlowMessage = "注册成功，请前往邮箱完成验证后再登录。"
                    authErrorMessage = nil
                    isAuthenticating = false
                    return .requiresEmailConfirmation
                }
            } else {
                session = try await supabaseService.signInWithEmail(email: normalizedEmail, password: trimmedPassword)
            }

            try await completeAuthenticatedSession(
                session: session,
                fallbackEmail: normalizedEmail,
                preferredNickname: shouldCreateAccount ? normalizedNickname : nil
            )
            if !shouldCreateAccount {
                clearEmailSignInFailures()
            }
            isAuthenticating = false
            return .signedIn
        } catch {
            authDebugLog("Email auth failed :: mode=\(shouldCreateAccount ? "signUp" : "signIn"), email=\(normalizedEmail), network=\(currentNetworkDebugDescription), error=\(error.localizedDescription)")
            clearPendingGuestCreditMigration()
            if let guestSessionToRestore {
                supabaseSession = guestSessionToRestore
                persistSession()
            } else {
                supabaseSession = nil
                clearStoredSession()
            }
            if !shouldCreateAccount,
               isInvalidEmailPasswordError(error),
               let rateLimitError = recordEmailSignInFailure() {
                authErrorMessage = rateLimitError.errorDescription
            } else {
                authErrorMessage = normalizedEmailAuthenticationErrorMessage(for: error)
            }
            isAuthenticating = false
            return .failed
        }
    }

    func requestPasswordReset(email: String) async -> Bool {
        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedEmail.isEmpty else {
            passwordResetErrorMessage = "请先输入邮箱地址。"
            return false
        }

        guard normalizedEmail.contains("@"), normalizedEmail.contains(".") else {
            passwordResetErrorMessage = "请输入正确的邮箱地址。"
            return false
        }

        guard isNetworkAvailable else {
            authDebugLog("Password reset request blocked before request :: network unavailable :: \(currentNetworkDebugDescription)")
            passwordResetErrorMessage = "当前网络不可用，请连接网络后再操作。"
            return false
        }

        do {
            try consumePasswordResetAttemptIfAllowed()
        } catch {
            passwordResetErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }

        isRequestingPasswordReset = true
        authErrorMessage = nil
        authFlowMessage = nil
        passwordResetErrorMessage = nil
        credentialWarningMessage = nil
        do {
            try await supabaseService.requestPasswordReset(email: normalizedEmail)
            authFlowMessage = "如果该邮箱已注册，我们会发送验证码邮件，请查收后输入验证码重置密码。"
            isRequestingPasswordReset = false
            return true
        } catch {
            authDebugLog("Password reset request failed :: email=\(normalizedEmail), network=\(currentNetworkDebugDescription), error=\(error.localizedDescription)")
            passwordResetErrorMessage = normalizedEmailAuthenticationErrorMessage(for: error)
            isRequestingPasswordReset = false
            return false
        }
    }

    func completePasswordReset(
        email: String,
        verificationCode: String,
        newPassword: String,
        confirmPassword: String
    ) async -> PasswordResetOutcome {
        let normalizedEmail = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedCode = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirmation = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEmail.isEmpty else {
            passwordResetErrorMessage = "请输入邮箱地址。"
            return .failed
        }

        guard !trimmedCode.isEmpty else {
            passwordResetErrorMessage = "请输入验证码。"
            return .failed
        }

        guard !trimmedPassword.isEmpty else {
            passwordResetErrorMessage = "请输入新密码。"
            return .failed
        }

        guard trimmedPassword.count >= 6 else {
            passwordResetErrorMessage = "密码长度不足，请至少输入 6 位。"
            return .failed
        }

        guard trimmedPassword == trimmedConfirmation else {
            passwordResetErrorMessage = "两次输入的密码不一致。"
            return .failed
        }

        guard isNetworkAvailable else {
            authDebugLog("Password reset completion blocked before request :: network unavailable :: \(currentNetworkDebugDescription)")
            passwordResetErrorMessage = "当前网络不可用，请连接网络后再操作。"
            return .failed
        }

        isUpdatingPassword = true
        passwordResetErrorMessage = nil
        authFlowMessage = nil
        credentialWarningMessage = nil
        do {
            let recoverySession = try await supabaseService.verifyRecoveryOTP(
                email: normalizedEmail,
                token: trimmedCode
            )
            try await supabaseService.updatePassword(session: recoverySession, newPassword: trimmedPassword)
            authFlowMessage = L10n.string("auth.reset_password.success", "密码修改成功，请重新登录")
            isUpdatingPassword = false
            return .updated
        } catch {
            authDebugLog("Password reset completion failed :: email=\(normalizedEmail), network=\(currentNetworkDebugDescription), error=\(error.localizedDescription)")
            passwordResetErrorMessage = normalizedPasswordResetVerificationErrorMessage(for: error)
            isUpdatingPassword = false
            return .failed
        }
    }

    func updateEnglishLevel(_ level: EnglishLevel) {
        englishLevel = level
        defaults.set(level.rawValue, forKey: AppStorageKey.englishLevel)
        Task {
            await syncPreferences()
        }
    }

    func updateLanguageStyle(_ style: LanguageStyle) {
        languageStyle = style
        defaults.set(style.rawValue, forKey: AppStorageKey.languageStyle)
        Task {
            await syncPreferences()
        }
    }

    func updateNickname(_ nickname: String) async throws {
        let validatedNickname = try NicknameValidator.validate(nickname)
        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SupabaseServiceError.apiError("请先登录后再修改昵称。")
        }

        guard let updatedProfile = try await supabaseService.updateProfile(
            session: session,
            nickname: validatedNickname
        ) else {
            throw SupabaseServiceError.invalidResponse
        }

        applyRemoteProfile(
            updatedProfile,
            fallbackAppleUserID: profile?.appleUserID ?? "",
            treatAsGuest: false
        )
        persistProfile()
    }

    func signOut() {
        guard !hasActiveGenerationTask else {
            credentialWarningMessage = L10n.string("profile.guard.generation_in_progress", "正在为您生成描述，请稍后操作。")
            return
        }
        guard !isSyncingPendingCloudChanges else { return }
        beginPendingLocalSignOutTransaction()
        completeLocalSignOutTransaction()
    }

    func deleteAccount() async throws {
        guard !hasActiveGenerationTask else {
            throw SupabaseServiceError.apiError(L10n.string("profile.guard.generation_in_progress", "正在为您生成描述，请稍后操作。"))
        }
        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SupabaseServiceError.apiError("当前是匿名状态，无需删除账号。")
        }
        beginPendingDeleteAccountLocalClear(session: session)
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        try await supabaseService.deleteAccount(session: session)
        markPendingDeleteAccountRemoteDeletionConfirmed(for: session.userID)
        completePendingDeleteAccountLocalClearIfNeeded()
    }

    func resetLocalAccountState(resetCredits: Bool) {
        postSignInSyncTask?.cancel()
        postSignInSyncTask = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        isRestoringAuthenticatedSession = false
        profile = nil
        memories = []
        clearPendingMemoryImageUploads()
        clearPendingGeneratedMemoryImage()
        pendingFavoriteChanges = []
        persistPendingFavoriteChanges()
        pendingMemoryDeletions = []
        persistPendingMemoryDeletions()
        isSyncingPendingCloudChanges = false
        pendingCloudSyncCompletedCount = 0
        pendingCloudSyncTotalCount = 0
        recordedMemoriesCount = 0
        favoriteSentencesCount = 0
        sentenceStudyDueCount = 0
        sentenceStudyTodayCount = 0
        sentenceStudyReviewableTodayCount = 0
        sentenceStudyQueue = []
        isLoadingSentenceStudyQueue = false
        isShowingSentenceStudySession = false
        sentenceStudyErrorMessage = nil
        draftLearningImageData = nil
        draftLearningItemIdentifier = nil
        draftGeneratedMemory = nil
        draftGeneratedMemoryID = nil
        authErrorMessage = nil
        authFlowMessage = nil
        credentialWarningMessage = nil
        purchaseErrorMessage = nil
        isCompletingPurchase = false
        isAuthenticating = false
        isRequestingPasswordReset = false
        isUpdatingPassword = false
        passwordResetErrorMessage = nil
        supabaseSession = nil
        if resetCredits {
            remainingCredits = 5
            persistCredits()
            defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
            defaults.removeObject(forKey: AppStorageKey.memories)
            defaults.removeObject(forKey: AppStorageKey.memoriesUserID)
        }
        clearStoredSession()
        defaults.removeObject(forKey: AppStorageKey.profile)
    }

    private func startPostSignInSync(
        session: SupabaseSession,
        preSignInGuestState: PreSignInGuestState
    ) {
        postSignInSyncTask?.cancel()
        let signedInUserID = session.userID

        postSignInSyncTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.postSignInSyncTask?.isCancelled != true else { return }
                    self.postSignInSyncTask = nil
                }
            }

            guard !Task.isCancelled, self.isCurrentSignedInUser(id: signedInUserID) else { return }
            await self.syncPendingCloudChanges(preSignInGuestState, showsProgress: true)

            guard !Task.isCancelled, self.isCurrentSignedInUser(id: signedInUserID) else { return }
            await self.syncMemoriesFromRemote(refreshCounts: true)
        }
    }

    private func isCurrentSignedInUser(id userID: String) -> Bool {
        hasAuthenticatedSession && supabaseSession?.userID == userID
    }

    func loadPersistedState() {
        completePendingLocalSignOutIfNeeded()
        completeRemoteConfirmedPendingDeleteAccountLocalClearIfNeeded()

        let decoder = JSONDecoder()
        let storedSession = loadStoredSession()
        let storedCreditsOwnerID = persistedCreditsOwnerID
        var didLoadPersistedProfile = false

        if let profileData = defaults.data(forKey: AppStorageKey.profile),
           let decodedProfile = PersistenceDiagnostics.decode(
               UserProfile.self,
               from: profileData,
               using: decoder,
               operation: "Decode persisted profile"
           ) {
            profile = decodedProfile
            didLoadPersistedProfile = true
        }

        if storedSession?.isAnonymous != false {
            profile = nil
            defaults.removeObject(forKey: AppStorageKey.profile)
        }

        if defaults.object(forKey: AppStorageKey.remainingCredits) != nil {
            if shouldRestorePersistedCredits(
                storedSession: storedSession,
                storedCreditsOwnerID: storedCreditsOwnerID,
                didLoadPersistedProfile: didLoadPersistedProfile
            ) {
                remainingCredits = defaults.integer(forKey: AppStorageKey.remainingCredits)
            } else {
                remainingCredits = 0
                defaults.set(0, forKey: AppStorageKey.remainingCredits)
                defaults.set(AppStorageKey.guestMemoriesUserID, forKey: AppStorageKey.remainingCreditsOwnerID)
            }
        }

        if let rawLevel = defaults.string(forKey: AppStorageKey.englishLevel),
           let storedLevel = EnglishLevel(rawValue: rawLevel) {
            englishLevel = storedLevel
        }

        if let rawStyle = defaults.string(forKey: AppStorageKey.languageStyle),
           let storedStyle = LanguageStyle(rawValue: rawStyle) {
            languageStyle = storedStyle
        }

        loadLearningReminderSettings()

        if let rawTransactionIDs = defaults.array(forKey: AppStorageKey.processedPurchaseTransactions) as? [String] {
            processedPurchaseTransactionIDs = Set(rawTransactionIDs)
        }

        loadPendingMemoryImageUploads()
        loadPendingGeneratedMemoryImage()
        loadPendingGuestMemoryMigrationQueue()
        loadLocalSentenceStudyProgress()
        loadPendingFavoriteChanges()
        loadPendingMemoryDeletions()
        loadPendingGuestCreditMigration()
        restoreCachedMemoriesForLaunch()
    }

    private func shouldRestorePersistedCredits(
        storedSession: SupabaseSession?,
        storedCreditsOwnerID: String?,
        didLoadPersistedProfile: Bool
    ) -> Bool {
        if let storedCreditsOwnerID {
            if storedCreditsOwnerID == AppStorageKey.guestMemoriesUserID {
                return true
            }

            guard let storedSession, storedSession.isAnonymous == false else {
                return false
            }

            return storedCreditsOwnerID == storedSession.userID
        }

        if didLoadPersistedProfile, storedSession?.isAnonymous != false {
            return false
        }

        return true
    }

    private func restoreCachedMemoriesForLaunch() {
        guard let cachedUserID = defaults.string(forKey: AppStorageKey.memoriesUserID) else {
            memories = []
            recordedMemoriesCount = 0
            favoriteSentencesCount = 0
            return
        }

        if let storedSession = loadStoredSession() {
            let launchCacheUserID = storedSession.isAnonymous
                ? AppStorageKey.guestMemoriesUserID
                : storedSession.userID

            guard cachedUserID == launchCacheUserID else {
                memories = []
                recordedMemoriesCount = 0
                favoriteSentencesCount = 0
                return
            }

            applyCachedMemoriesIfAvailable(for: launchCacheUserID, imageLoading: .deferRemoteBacked)
            if !storedSession.isAnonymous {
                mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded(persistUserID: launchCacheUserID)
            }
            return
        }

        guard cachedUserID == AppStorageKey.guestMemoriesUserID else {
            memories = []
            recordedMemoriesCount = 0
            favoriteSentencesCount = 0
            return
        }

        applyCachedMemoriesIfAvailable(for: AppStorageKey.guestMemoriesUserID, imageLoading: .deferRemoteBacked)
    }

    func startNetworkMonitoring() {
        networkStatusMonitor.start { [weak self] isSatisfied, debugDescription in
            DispatchQueue.main.async {
                let wasAvailable = self?.isNetworkAvailable ?? false
                self?.isNetworkAvailable = isSatisfied
                self?.authDebugLog("Network path update :: \(debugDescription)")
                if isSatisfied && !wasAvailable, let appModel = self {
                    Task {
                        await appModel.retryPendingPurchasesIfNeeded()
                        await appModel.retryPendingMemoryImageUploadsIfNeeded()
                        if appModel.hasAuthenticatedSession {
                            await appModel.refreshRemoteContent()
                        }
                    }
                }
            }
        }
    }

    func restoreRemoteSessionIfPossible() async {
        guard let storedSession = loadStoredSession() else {
            isRestoringAuthenticatedSession = false
            return
        }

        isRestoringAuthenticatedSession = !storedSession.isAnonymous
        defer {
            if !hasAuthenticatedSession {
                isRestoringAuthenticatedSession = false
            }
        }

        do {
            let sessionToUse: SupabaseSession
            if storedSession.expiresAt <= Date().addingTimeInterval(60) {
                sessionToUse = try await supabaseService.refreshSession(refreshToken: storedSession.refreshToken)
            } else {
                sessionToUse = storedSession
            }

            let cacheUserID = sessionToUse.isAnonymous ? AppStorageKey.guestMemoriesUserID : sessionToUse.userID
            applyCachedMemoriesIfAvailable(for: cacheUserID, imageLoading: .deferRemoteBacked)
            if !sessionToUse.isAnonymous {
                mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded(persistUserID: cacheUserID)
            }

            if sessionToUse.isAnonymous {
                supabaseSession = sessionToUse
                persistSession()
                await retryPendingPurchasesIfNeeded()
                return
            }

            let resolvedProfile: SupabaseProfileRecord
            if let migratedProfile = await retryPendingGuestCreditMigrationIfNeeded(for: sessionToUse) {
                resolvedProfile = migratedProfile
            } else if let remoteProfile = try await supabaseService.fetchProfile(session: sessionToUse) {
                resolvedProfile = remoteProfile
                clearPendingDeleteAccountLocalClearIfNeeded(for: sessionToUse.userID)
            } else {
                revertIncompleteAuthenticatedRestoreToGuest()
                return
            }

            supabaseSession = sessionToUse
            persistSession()
            applyRemoteProfile(
                resolvedProfile,
                fallbackAppleUserID: profile?.appleUserID ?? "",
                treatAsGuest: sessionToUse.isAnonymous
            )
            isRestoringAuthenticatedSession = false
            persistProfile()
            persistCredits()

            await retryPendingPurchasesIfNeeded()
            await retryPendingMemoryImageUploadsIfNeeded()
            await syncPendingCloudChanges(showsProgress: true)
            await syncMemoriesFromRemote(refreshCounts: true)
        } catch {
            if shouldClearStoredSession(for: error) {
                handleDeletedAuthenticatedAccountLocally()
            }
            isRestoringAuthenticatedSession = false
        }
    }

    func ensureRemoteSessionRestoreCompleted() async {
        if let sessionRestoreTask {
            await sessionRestoreTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreRemoteSessionIfPossible()
        }
        sessionRestoreTask = task
        await task.value
        sessionRestoreTask = nil
    }

    func applyRemoteProfile(
        _ remoteProfile: SupabaseProfileRecord,
        fallbackAppleUserID: String,
        treatAsGuest: Bool = false
    ) {
        if treatAsGuest {
            profile = nil
        } else {
            let resolvedNickname = Self.isSystemGeneratedNickname(remoteProfile.nickname)
                ? "用户"
                : remoteProfile.nickname
            profile = UserProfile(
                appleUserID: remoteProfile.appleUserID ?? fallbackAppleUserID,
                nickname: resolvedNickname,
                email: remoteProfile.email
            )
        }
        remainingCredits = remoteProfile.availableGenerations
        englishLevel = EnglishLevel(rawValue: remoteProfile.englishLevel) ?? englishLevel
        languageStyle = LanguageStyle(rawValue: remoteProfile.languageStyle) ?? languageStyle
        defaults.set(englishLevel.rawValue, forKey: AppStorageKey.englishLevel)
        defaults.set(languageStyle.rawValue, forKey: AppStorageKey.languageStyle)
    }

    func ensureValidSession() async throws -> SupabaseSession {
        guard let currentSession = supabaseSession else {
            if let storedSession = loadStoredSession() {
                let validSession = try await ensureFreshSessionIfNeeded(storedSession)
                supabaseSession = validSession
                persistSession()
                if validSession.isAnonymous {
                    try await ensureAnonymousProfileExists(for: validSession)
                    persistCredits()
                }
                return validSession
            }

            await ensureAnonymousSessionIfPossible()
            guard let restoredSession = supabaseSession else {
                throw KimiServiceError.sessionUnavailable
            }
            let validSession = try await ensureFreshSessionIfNeeded(restoredSession)
            if validSession.isAnonymous {
                try await ensureAnonymousProfileExists(for: validSession)
                persistCredits()
            }
            return validSession
        }

        let validSession = try await ensureFreshSessionIfNeeded(currentSession)
        if validSession.isAnonymous {
            try await ensureAnonymousProfileExists(for: validSession)
            persistCredits()
        }
        return validSession
    }

    func ensureAnonymousSessionIfPossible() async {
        guard supabaseSession == nil else { return }
        guard supabaseService.isConfigured, isNetworkAvailable else { return }

        do {
            let anonymousSession = try await supabaseService.signInAnonymously()
            supabaseSession = anonymousSession
            persistSession()
            if hasCachedMemories(for: AppStorageKey.guestMemoriesUserID) {
                applyCachedMemoriesIfAvailable(for: AppStorageKey.guestMemoriesUserID)
            } else if !memories.isEmpty {
                persistMemories(for: AppStorageKey.guestMemoriesUserID)
            }
            try await ensureAnonymousProfileExists(for: anonymousSession)
            persistCredits()
        } catch {
            return
        }
    }

    func forceRefreshSession() async throws -> SupabaseSession {
        guard let currentSession = supabaseSession else {
            throw KimiServiceError.sessionUnavailable
        }

        let refreshedSession = try await supabaseService.refreshSession(refreshToken: currentSession.refreshToken)
        supabaseSession = refreshedSession
        persistSession()
        return refreshedSession
    }

    func ensureFreshSessionIfNeeded(_ session: SupabaseSession) async throws -> SupabaseSession {
        if session.expiresAt > Date().addingTimeInterval(60) {
            return session
        }

        let refreshedSession = try await supabaseService.refreshSession(refreshToken: session.refreshToken)
        supabaseSession = refreshedSession
        persistSession()
        return refreshedSession
    }

    func syncPreferences() async {
        guard let session = try? await ensureValidSession() else { return }
        _ = try? await supabaseService.updateProfile(
            session: session,
            englishLevel: englishLevel,
            languageStyle: languageStyle
        )
    }

    func shouldClearStoredSession(for error: Error) -> Bool {
        guard let serviceError = error as? SupabaseServiceError else {
            return false
        }

        guard case let .apiError(message) = serviceError else {
            return false
        }

        let normalized = message.lowercased()
        let explicitInvalidRefreshTokenMessages = [
            "invalid refresh token",
            "refresh token not found",
            "refresh token has been revoked",
            "refresh token already used",
            "invalid_grant",
            "grant type not supported"
        ]

        if explicitInvalidRefreshTokenMessages.contains(where: { normalized.contains($0) }) {
            return true
        }

        let refreshTokenSignals = [
            "refresh token",
            "refresh_token",
            "grant_type=refresh_token"
        ]

        let mentionsRefreshToken = refreshTokenSignals.contains(where: { normalized.contains($0) })

        if mentionsRefreshToken && normalized.contains("revoked") {
            return true
        }

        if mentionsRefreshToken && normalized.contains("expired") {
            return true
        }

        return false
    }

    func handleDeletedAuthenticatedAccountLocally() {
        guard !completePendingDeleteAccountLocalClearIfNeeded() else { return }

        resetLocalAccountState(resetCredits: false)
        clearLearningDraft()
        clearPersistedMemories()
        clearPendingGuestMemoryMigrationQueue()
        clearPendingGuestCreditMigration()
        clearLocalSentenceStudyProgress()
        remainingCredits = 0
        persistCredits()
        defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
    }

#if DEBUG
    func resetInitialCreditsGrantForDebug() {
        KeychainStorage.remove(for: AppStorageKey.initialCreditsGrantMarker)
        KeychainStorage.remove(for: AppStorageKey.supabaseSession)
        defaults.removeObject(forKey: AppStorageKey.installMarker)
        clearStoredSession()
    }
#endif

#if DEBUG || STAGING
    func resetLocalTestDataForFreshInstall() {
        resetLocalAccountState(resetCredits: false)
        clearLearningDraft()
        clearPersistedMemories()
        clearPendingGuestMemoryMigrationQueue()
        clearPendingGuestCreditMigration()
        clearLocalSentenceStudyProgress()
        disableLearningReminder()
        LearningReminderNotificationRoute.clearOpenFavoritesRequest()

        [
            AppStorageKey.installMarker,
            AppStorageKey.profile,
            AppStorageKey.memories,
            AppStorageKey.memoriesUserID,
            AppStorageKey.pendingMemoryImageUploads,
            AppStorageKey.pendingGeneratedMemoryImage,
            AppStorageKey.pendingGuestMemoryMigrationQueue,
            AppStorageKey.pendingFavoriteChanges,
            AppStorageKey.pendingMemoryDeletions,
            AppStorageKey.pendingGuestCreditMergeLegacy,
            AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile,
            AppStorageKey.pendingLocalAccountTransition,
            AppStorageKey.generationAttemptTimestamps,
            AppStorageKey.passwordResetAttemptTimestamps,
            AppStorageKey.emailSignInFailureTimestamps,
            AppStorageKey.remainingCredits,
            AppStorageKey.remainingCreditsOwnerID,
            AppStorageKey.englishLevel,
            AppStorageKey.languageStyle,
            AppStorageKey.learningReminderEnabled,
            AppStorageKey.learningReminderHour,
            AppStorageKey.learningReminderMinute,
            AppStorageKey.localSentenceStudyProgress,
            AppStorageKey.processedPurchaseTransactions
        ].forEach(defaults.removeObject)

        KeychainStorage.remove(for: AppStorageKey.supabaseSession)
        KeychainStorage.remove(for: AppStorageKey.pendingGuestCreditMigration)
        KeychainStorage.remove(for: AppStorageKey.initialCreditsGrantMarker)

        profile = nil
        memories = []
        processedPurchaseTransactionIDs = []
        processingPurchaseTransactionIDs = []
        pendingGuestCreditMigration = nil
        englishLevel = .simple
        languageStyle = .plain
        isLearningReminderEnabled = false
        learningReminderHour = 20
        learningReminderMinute = 30
        remainingCredits = 5

        handleFreshInstallIfNeeded()
    }
#endif

    private func normalizedEmailAuthenticationErrorMessage(for error: Error) -> String {
        if case let SupabaseServiceError.apiError(rawMessage) = error {
            let normalized = rawMessage.lowercased()
            if normalized.contains("request time out") ||
                normalized.contains("request timed out") ||
                normalized.contains("timed out") ||
                normalized.contains("timeout") {
                return L10n.string("auth_error.network_timeout", "网络连接超时，请检查当前网络后重试。")
            }
            if normalized.contains("network connection was lost") ||
                normalized.contains("connection was lost") ||
                normalized.contains("network connection") && normalized.contains("lost") {
                return L10n.string("auth_error.network_lost", "网络连接已中断，请检查当前网络后重试。")
            }
            if normalized.contains("error sending recovery email") ||
                normalized.contains("sending recovery email") {
                return L10n.string("auth_error.recovery_email_failed", "验证码邮件发送失败，请稍后再试。")
            }
            if normalized.contains("bad gateway") ||
                normalized.contains("gateway") ||
                normalized.contains("service unavailable") ||
                normalized.contains("server_error") ||
                normalized.contains("internal server error") {
                return L10n.string("auth_error.service_unavailable", "登录服务暂时异常，请稍后再试。")
            }
        }

        if let serviceError = error as? SupabaseServiceError,
           let description = serviceError.errorDescription {
            return description
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return L10n.string("auth_error.email_auth_failed", "邮箱登录失败，请稍后重试。")
        }
        return message
    }

    private func normalizedPasswordResetVerificationErrorMessage(for error: Error) -> String {
        guard case let SupabaseServiceError.apiError(rawMessage) = error else {
            return normalizedEmailAuthenticationErrorMessage(for: error)
        }

        let normalized = rawMessage.lowercased()
        if normalized.contains("invalid otp") ||
            normalized.contains("otp is invalid") ||
            normalized.contains("invalid token") ||
            normalized.contains("token is invalid") ||
            normalized.contains("invalid grant") ||
            normalized.contains("email link is invalid") ||
            normalized.contains("invalid or expired") ||
            normalized.contains("expired or invalid") {
            return L10n.string("supabase_error.invalid_otp", "验证码不正确。")
        }

        if normalized.contains("otp_expired") ||
            normalized.contains("token has expired") ||
            normalized.contains("expired otp") ||
            normalized.contains("expired token") {
            return L10n.string("supabase_error.otp_expired", "验证码已过期，请重新获取。")
        }

        return normalizedEmailAuthenticationErrorMessage(for: error)
    }

    private func isInvalidEmailPasswordError(_ error: Error) -> Bool {
        guard case let SupabaseServiceError.apiError(rawMessage) = error else {
            return false
        }

        return rawMessage
            .lowercased()
            .contains("invalid login credentials")
    }

    static func randomNickname() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<6).compactMap { _ in letters.randomElement() })
        return "user_\(suffix)"
    }

    private func preferredNicknameForEmail(_ email: String) -> String {
        if let existingNickname = profile?.nickname.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingNickname.isEmpty,
           !Self.isSystemGeneratedNickname(existingNickname) {
            return existingNickname
        }

        let localPart = email.split(separator: "@").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !localPart.isEmpty {
            let asciiLettersAndDigits = localPart.filter { character in
                character.isASCII && (character.isLetter || character.isNumber)
            }
            if let firstLetterIndex = asciiLettersAndDigits.firstIndex(where: \.isLetter) {
                let candidate = String(asciiLettersAndDigits[firstLetterIndex...].prefix(20))
                if let validatedNickname = try? NicknameValidator.validate(candidate) {
                    return validatedNickname
                }
            }
        }

        return Self.randomNickname()
    }

    private func resolvedPreferredNickname(
        explicitNickname: String?,
        currentUser: SupabaseCurrentAuthUserResponse,
        fallbackEmail: String
    ) -> String {
        if let explicitNickname,
           let validatedNickname = try? NicknameValidator.validate(explicitNickname) {
            return validatedNickname
        }

        if let metadataNickname = currentUser.userMetadata?.nickname,
           let validatedNickname = try? NicknameValidator.validate(metadataNickname) {
            return validatedNickname
        }

        return preferredNicknameForEmail(fallbackEmail)
    }

    private func prepareGuestMemoriesForAuthenticatedFlowIfNeeded() {
        let guestMemoriesForMigration = memories.filter { memory in
            isMemoryContentComplete(memory) && !memory.syncedToAccount
        }
        if !guestMemoriesForMigration.isEmpty {
            replacePendingGuestMemoryMigrationQueue(with: guestMemoriesForMigration)
            persistMemories(for: AppStorageKey.guestMemoriesUserID)
        }
    }

    private func completeAuthenticatedSession(
        session: SupabaseSession,
        fallbackEmail: String?,
        preferredNickname: String?
    ) async throws {
        let preSignInGuestState = PreSignInGuestState(
            pendingMemoryDeletions: pendingMemoryDeletions
        )

        let preparedGuestCreditMigration = try await prepareGuestCreditMigrationIfNeeded()
        let currentUser = try await supabaseService.fetchCurrentUser(session: session)

        let baseProfile: SupabaseProfileRecord
        if let remoteProfile = try await supabaseService.fetchProfile(session: session) {
            baseProfile = remoteProfile
        } else {
            let fallbackIdentifier = "email:\(session.userID)"
            let resolvedNickname = resolvedPreferredNickname(
                explicitNickname: preferredNickname,
                currentUser: currentUser,
                fallbackEmail: currentUser.email ?? fallbackEmail ?? ""
            )
            baseProfile = try await supabaseService.upsertProfile(
                session: session,
                appleUserID: fallbackIdentifier,
                nickname: resolvedNickname,
                email: currentUser.email ?? fallbackEmail,
                englishLevel: englishLevel,
                languageStyle: languageStyle
            )
        }

        var finalProfile = baseProfile
        if let preparedGuestCreditMigration,
           preparedGuestCreditMigration.guestSession.userID != session.userID {
            finalProfile = try await supabaseService.migrateGuestCredits(
                session: session,
                guestRefreshToken: preparedGuestCreditMigration.guestSession.refreshToken,
                guestUserID: preparedGuestCreditMigration.guestSession.userID
            )
        }

        clearPendingGuestCreditMigration()
        clearGuestCreditRecoveryWarningIfNeeded()
        supabaseSession = session
        persistSession()
        if hasCachedMemories(for: session.userID) {
            applyCachedMemoriesIfAvailable(for: session.userID)
        }
        mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded(persistUserID: session.userID)
        applyRemoteProfile(finalProfile, fallbackAppleUserID: "email:\(session.userID)", treatAsGuest: false)
        persistProfile()
        persistCredits()
        defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
        clearPendingGeneratedMemoryImage()
        startPostSignInSync(session: session, preSignInGuestState: preSignInGuestState)
    }

    private static func isSystemGeneratedNickname(_ nickname: String) -> Bool {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.hasPrefix("user_") || trimmed.hasPrefix("apple:") || trimmed.hasPrefix("anonymous:") {
            return true
        }

        return UUID(uuidString: trimmed) != nil
    }

    private func prepareProfileIfNeeded(
        for session: SupabaseSession,
        fallbackAppleUserID: String,
        preferredNickname: String,
        preferredEmail: String?,
        initialAvailableGenerations: Int? = nil
    ) async throws {
        if let remoteProfile = try await supabaseService.fetchProfile(session: session) {
            applyRemoteProfile(remoteProfile, fallbackAppleUserID: fallbackAppleUserID, treatAsGuest: session.isAnonymous)
            persistProfile()
            return
        }

        let allowedInitialCredits = session.isAnonymous
            ? initialAvailableGenerations.map { min(max($0, 0), initialInstallCredits) }
            : nil
        let createdProfile = try await supabaseService.upsertProfile(
            session: session,
            appleUserID: fallbackAppleUserID,
            nickname: preferredNickname,
            email: preferredEmail,
            englishLevel: englishLevel,
            languageStyle: languageStyle,
            initialAvailableGenerations: allowedInitialCredits
        )
        applyRemoteProfile(createdProfile, fallbackAppleUserID: fallbackAppleUserID, treatAsGuest: session.isAnonymous)
        persistProfile()
    }

    private func ensureAnonymousProfileExists(for session: SupabaseSession) async throws {
        guard session.isAnonymous else { return }

        if let remoteProfile = try await supabaseService.fetchProfile(session: session) {
            if localCreditsBelongToGuest {
                if remoteProfile.availableGenerations > remainingCredits {
                    let updatedProfile = try await supabaseService.updateAnonymousStarterCredits(
                        session: session,
                        availableGenerations: remainingCredits
                    )
                    if let updatedProfile {
                        applyRemoteProfile(updatedProfile, fallbackAppleUserID: "anonymous:\(session.userID)", treatAsGuest: true)
                        persistCredits()
                    }
                } else if remoteProfile.availableGenerations < remainingCredits {
                    guard !shouldPreserveRestoredGuestCreditsAgainstAnonymousProfile else {
                        return
                    }
                    remainingCredits = remoteProfile.availableGenerations
                    persistCredits()
                }
            } else if remoteProfile.availableGenerations != remainingCredits {
                remainingCredits = remoteProfile.availableGenerations
                persistCredits()
            }
            return
        }

        let initialGuestCredits = localCreditsBelongToGuest ? remainingCredits : 0

        let createdProfile = try await supabaseService.upsertProfile(
            session: session,
            appleUserID: "anonymous:\(session.userID)",
            nickname: profile?.nickname ?? Self.randomNickname(),
            email: nil,
            englishLevel: englishLevel,
            languageStyle: languageStyle,
            initialAvailableGenerations: initialGuestCredits
        )

        if !localCreditsBelongToGuest {
            remainingCredits = createdProfile.availableGenerations
            persistCredits()
        }
    }

    private func prepareGuestCreditMigrationIfNeeded() async throws -> PreparedGuestCreditMigration? {
        if let anonymousSession = supabaseSession, anonymousSession.isAnonymous {
            let validSession = try await ensureFreshSessionIfNeeded(anonymousSession)
            try await ensureAnonymousProfileExists(for: validSession)
            return PreparedGuestCreditMigration(guestSession: validSession)
        }

        guard remainingCredits > 0, localCreditsBelongToGuest else {
            return nil
        }

        await ensureAnonymousSessionIfPossible()

        guard let anonymousSession = supabaseSession, anonymousSession.isAnonymous else {
            throw GuestCreditPreparationError.unavailable
        }

        let validSession = try await ensureFreshSessionIfNeeded(anonymousSession)
        try await ensureAnonymousProfileExists(for: validSession)
        return PreparedGuestCreditMigration(guestSession: validSession)
    }

    func retryPendingGuestCreditMigrationIfNeeded(for session: SupabaseSession) async -> SupabaseProfileRecord? {
        guard !session.isAnonymous else { return nil }
        guard let pendingGuestCreditMigration else {
            clearGuestCreditRecoveryWarningIfNeeded()
            return nil
        }
        guard pendingGuestCreditMigration.accountUserID == session.userID else { return nil }

        do {
            let profile = try await supabaseService.migrateGuestCredits(
                session: session,
                guestRefreshToken: pendingGuestCreditMigration.guestRefreshToken,
                guestUserID: pendingGuestCreditMigration.guestUserID
            )
            clearPendingGuestCreditMigration()
            clearGuestCreditRecoveryWarningIfNeeded()
            return profile
        } catch {
            credentialWarningMessage = "访客可用次数仍在恢复中，请保持网络连接后稍后再试。"
            return nil
        }
    }

    private func clearGuestCreditRecoveryWarningIfNeeded() {
        guard let credentialWarningMessage,
              Self.guestCreditRecoveryWarningMessages.contains(credentialWarningMessage) else {
            return
        }
        self.credentialWarningMessage = nil
    }

    private func revertIncompleteAuthenticatedRestoreToGuest() {
        postSignInSyncTask?.cancel()
        postSignInSyncTask = nil
        foregroundSyncTask?.cancel()
        foregroundSyncTask = nil
        isSyncingPendingCloudChanges = false
        pendingCloudSyncCompletedCount = 0
        pendingCloudSyncTotalCount = 0
        profile = nil
        persistProfile()
        supabaseSession = nil
        clearStoredSession()
        remainingCredits = 0
        persistCredits()
        defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
        applyCachedMemoriesIfAvailable(for: AppStorageKey.guestMemoriesUserID)
        credentialWarningMessage = Self.interruptedSignInRecoveryMessage
    }

    private func migrateGuestMemoriesToCurrentAccount(using remoteMemories: [MemoryEntry]) async {
        let queuedMemories = pendingGuestMemoriesToMigrate()
        guard !queuedMemories.isEmpty else { return }
        guard let session = supabaseSession, !session.isAnonymous else { return }

        var migratedMemories = memories

        for guestMemory in queuedMemories {
            defer { advancePendingCloudSyncProgress() }

            if let remoteMatch = remoteMemories.first(where: { matchesMemoryIdentity($0, guestMemory) }) {
                if let existingIndex = migratedMemories.firstIndex(where: { $0.id == guestMemory.id }) {
                    migratedMemories[existingIndex] = remoteMatch
                }
                removePendingGuestMemoryMigration(memoryID: guestMemory.id)
                continue
            }

            guard !guestMemory.imageData.isEmpty else { continue }

            do {
                let migratedMemory = try await supabaseService.createMemoryCopy(session: session, memory: guestMemory)
                if let existingIndex = migratedMemories.firstIndex(where: { $0.id == guestMemory.id }) {
                    migratedMemories[existingIndex] = migratedMemory
                } else {
                    migratedMemories.insert(migratedMemory, at: 0)
                }
                removePendingGuestMemoryMigration(memoryID: guestMemory.id)
            } catch {
                authErrorMessage = "本地回忆同步失败：\(error.localizedDescription)"
                continue
            }
        }

        migratedMemories.sort { $0.createdAt > $1.createdAt }
        memories = migratedMemories
        recordedMemoriesCount = migratedMemories.count
        favoriteSentencesCount = migratedMemories.reduce(into: 0) { partialResult, memory in
            partialResult += memory.sentences.filter(\.isFavorite).count
        }
        persistMemories()
    }

    private func pendingGuestMemoriesToMigrate() -> [MemoryEntry] {
        let persistedQueuedMemories = pendingGuestMemoryMigrationQueue
            .filter(isMemoryContentComplete)
            .sorted { $0.createdAt > $1.createdAt }

        if !persistedQueuedMemories.isEmpty {
            return persistedQueuedMemories
        }

        return memories
            .filter { isMemoryContentComplete($0) && !$0.syncedToAccount }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func syncFavoriteDifferencesIfNeeded(using remoteMemories: [MemoryEntry]) async {
        guard let session = supabaseSession, !session.isAnonymous else { return }

        let queuedSentenceIDs = Set(pendingFavoriteChanges.map(\.sentenceID))
        let remoteMemoryByID = Dictionary(uniqueKeysWithValues: remoteMemories.map { ($0.id, $0) })

        for localMemory in memories where localMemory.syncedToAccount {
            guard let remoteMemory = remoteMemoryByID[localMemory.id] else { continue }

            let remoteSentenceByID = Dictionary(uniqueKeysWithValues: remoteMemory.sentences.map { ($0.id, $0) })
            for localSentence in localMemory.sentences {
                guard !queuedSentenceIDs.contains(localSentence.id),
                      let remoteSentence = remoteSentenceByID[localSentence.id],
                      remoteSentence.isFavorite != localSentence.isFavorite else {
                    continue
                }

                defer { advancePendingCloudSyncProgress() }

                do {
                    try await supabaseService.updateSentenceFavorite(
                        session: session,
                        sentenceID: localSentence.id,
                        isFavorite: localSentence.isFavorite
                    )
                } catch {
                    queuePendingFavoriteChange(
                        sentenceID: localSentence.id,
                        isFavorite: localSentence.isFavorite
                    )
                    continue
                }
            }
        }
    }

    private func syncPendingFavoriteChangesIfNeeded() async {
        guard !pendingFavoriteChanges.isEmpty else { return }
        guard let session = supabaseSession, !session.isAnonymous else { return }

        let queuedChanges = pendingFavoriteChanges
        let queuedChangeSet = Set(queuedChanges)
        var remainingChanges: [PendingFavoriteChange] = []
        var didUpdateLocalFavorite = false

        for change in queuedChanges {
            defer { advancePendingCloudSyncProgress() }

            guard locateSentence(change.sentenceID) != nil else {
                continue
            }

            do {
                try await supabaseService.updateSentenceFavorite(
                    session: session,
                    sentenceID: change.sentenceID,
                    isFavorite: change.isFavorite
                )
                if let location = locateSentence(change.sentenceID) {
                    memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite = change.isFavorite
                    didUpdateLocalFavorite = true
                }
            } catch {
                remainingChanges.append(change)
            }
        }

        let remainingChangeSet = Set(remainingChanges)
        pendingFavoriteChanges = pendingFavoriteChanges.filter { change in
            guard queuedChangeSet.contains(change) else { return true }
            return remainingChangeSet.contains(change)
        }
        persistPendingFavoriteChanges()
        if didUpdateLocalFavorite {
            favoriteSentencesCount = memories.reduce(into: 0) { partialResult, memory in
                partialResult += memory.sentences.filter(\.isFavorite).count
            }
            persistMemories()
        }
    }

    func syncPendingMemoryDeletionsIfNeeded() async {
        guard !pendingMemoryDeletions.isEmpty else { return }
        guard let session = supabaseSession, !session.isAnonymous else { return }

        var remainingDeletions: [PendingMemoryDeletion] = []

        for deletion in pendingMemoryDeletions {
            defer { advancePendingCloudSyncProgress() }

            do {
                try await supabaseService.deleteMemory(
                    session: session,
                    memoryID: deletion.memoryID,
                    imagePath: deletion.remoteImagePath
                )
            } catch {
                remainingDeletions.append(deletion)
            }
        }

        pendingMemoryDeletions = remainingDeletions
        persistPendingMemoryDeletions()
    }

    private func localSentenceStudyProgressToMerge() -> [LocalSentenceStudyProgress] {
        localSentenceStudyProgress.values.filter { progress in
            guard let location = locateSentence(progress.sentenceID) else { return false }
            return memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite
        }
    }

    private func syncLocalSentenceStudyProgressIfNeeded() async {
        let progressRecords = localSentenceStudyProgressToMerge()
        guard !progressRecords.isEmpty else { return }
        guard let session = supabaseSession, !session.isAnonymous else { return }

        do {
            let mergedSentenceIDs = try await supabaseService.mergeLocalSentenceStudyProgress(
                session: session,
                progressRecords: progressRecords
            )
            guard !mergedSentenceIDs.isEmpty else { return }

            for _ in mergedSentenceIDs {
                advancePendingCloudSyncProgress()
            }
            localSentenceStudyProgress = localSentenceStudyProgress.filter { sentenceID, _ in
                !mergedSentenceIDs.contains(sentenceID)
            }
            persistLocalSentenceStudyProgress()
        } catch {
            pendingCloudSyncDebugLog("local sentence study progress merge failed: \(error.localizedDescription)")
        }
    }

    func syncPendingCloudChangesIfNeeded() async {
        await syncPendingCloudChanges(showsProgress: true)
    }

    fileprivate func syncPendingCloudChanges(
        _ state: PreSignInGuestState? = nil,
        showsProgress: Bool = false
    ) async {
        guard isSignedIn, let session = supabaseSession else {
            if showsProgress {
                isSyncingPendingCloudChanges = false
                pendingCloudSyncCompletedCount = 0
                pendingCloudSyncTotalCount = 0
            }
            return
        }

        let queuedGuestMemories = pendingGuestMemoriesToMigrate()
        let remoteRecords: [SupabaseMemoryRecord]
        do {
            remoteRecords = try await supabaseService.fetchMemories(session: session)
        } catch {
            pendingCloudSyncDebugLog("remote fetch failed before sync: \(error.localizedDescription)")
            remoteRecords = []
        }

        let remoteMemories = cloudSyncManager.makeRemoteMemories(from: remoteRecords)

        reconcileLocalMemoriesWithRemote(remoteMemories, sessionUserID: session.userID)
        let queuedMemoryDeletions = state?.pendingMemoryDeletions ?? pendingMemoryDeletions
        let queuedFavoriteChanges = pendingFavoriteChanges
        let queuedLocalStudyProgress = localSentenceStudyProgressToMerge()
        let cloudSyncPlan = cloudSyncManager.makePlan(
            localMemories: memories,
            remoteMemories: remoteMemories,
            queuedGuestMemories: queuedGuestMemories,
            queuedMemoryDeletions: queuedMemoryDeletions,
            queuedFavoriteChanges: queuedFavoriteChanges,
            queuedLocalStudyProgress: queuedLocalStudyProgress
        )
        if cloudSyncPlan.totalCount > 0 {
            pendingCloudSyncDebugLog(
                cloudSyncPlan.debugDescription(
                    sessionID: session.userID,
                    localMemoryCount: memories.count,
                    remoteMemoryCount: remoteMemories.count
                )
            )
        }
        guard cloudSyncPlan.totalCount > 0 else { return }

        if showsProgress {
            isSyncingPendingCloudChanges = true
            pendingCloudSyncCompletedCount = 0
            pendingCloudSyncTotalCount = cloudSyncPlan.totalCount
        }
        defer {
            if showsProgress {
                isSyncingPendingCloudChanges = false
                pendingCloudSyncCompletedCount = 0
                pendingCloudSyncTotalCount = 0
            }
        }

        await migrateGuestMemoriesToCurrentAccount(using: remoteMemories)
        await syncPendingMemoryDeletionsIfNeeded()
        await syncPendingFavoriteChangesIfNeeded()
        await syncFavoriteDifferencesIfNeeded(using: remoteMemories)
        await syncLocalSentenceStudyProgressIfNeeded()
        await refreshSentenceStudyDueCount()
    }

    private func reconcileLocalMemoriesWithRemote(_ remoteMemories: [MemoryEntry], sessionUserID: String) {
        let result = cloudSyncManager.reconcileLocalMemories(
            localMemories: memories,
            remoteMemories: remoteMemories,
            sessionUserID: sessionUserID
        )
        guard result.didChange else { return }

        memories = result.memories
        recordedMemoriesCount = result.recordedMemoriesCount
        favoriteSentencesCount = result.favoriteSentencesCount
        persistMemories()
    }

    private func advancePendingCloudSyncProgress() {
        guard isSyncingPendingCloudChanges else { return }
        pendingCloudSyncCompletedCount = min(
            pendingCloudSyncCompletedCount + 1,
            pendingCloudSyncTotalCount
        )
    }
}
