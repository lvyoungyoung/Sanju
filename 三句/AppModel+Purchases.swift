import Foundation

extension AppModel {
    private enum PurchaseGrantApplicationError: LocalizedError {
        case missingAppAccountToken
        case appAccountTokenMismatch
        case invalidPurchaseSession
        case accountRestoreInProgress
        case authenticatedProfileUnavailable

        var errorDescription: String? {
            switch self {
            case .missingAppAccountToken:
                return "购买记录缺少账号标识，无法安全同步。请重新发起购买。"
            case .appAccountTokenMismatch:
                return "这笔购买不属于当前账号，请切换回购买时的账号后重试。"
            case .invalidPurchaseSession:
                return "暂时无法建立购买会话，请检查网络后重试。"
            case .accountRestoreInProgress:
                return "账号正在恢复中，请稍后再购买。"
            case .authenticatedProfileUnavailable:
                return "账号信息还没有准备好，请稍后再购买。"
            }
        }
    }

    func loadPurchaseOffers() async {
        do {
            try await purchaseManager.loadOffers()
            purchaseErrorMessage = nil
        } catch {
            purchaseErrorMessage = error.localizedDescription
        }
    }

    func purchaseProduct(productID: String) async {
        guard !isStartingPurchase, !purchaseManager.isPurchasing, !isCompletingPurchase else {
            return
        }

        guard !isRestoringAuthenticatedSession else {
            purchaseErrorMessage = PurchaseGrantApplicationError.accountRestoreInProgress.localizedDescription
            return
        }

        isStartingPurchase = true
        defer { isStartingPurchase = false }

        do {
            let purchaseSession = try await preparePurchaseSession()
            let appAccountToken = try purchaseAppAccountToken(for: purchaseSession)
            let grant = try await purchaseManager.purchase(
                productID: productID,
                appAccountToken: appAccountToken
            )
            isCompletingPurchase = true
            defer { isCompletingPurchase = false }
            let didApply = await applyPurchaseGrantIfNeeded(grant)
            if didApply {
                purchaseErrorMessage = nil
            }
        } catch {
            isCompletingPurchase = false
            purchaseErrorMessage = error.localizedDescription
        }
    }

    func syncPurchase(_ grant: PurchaseGrant) async throws -> Int {
        let session = try await validatedSession(for: grant)
        return try await supabaseService.confirmPurchase(
            session: session,
            transactionID: grant.transactionID,
            productID: grant.productID
        )
    }

    func processUnfinishedPurchases() async {
        let grants = await purchaseManager.syncUnfinishedPurchases()
        for grant in grants {
            _ = await applyPurchaseGrantIfNeeded(grant)
        }
    }

    func retryPendingPurchasesIfNeeded() async {
        guard !isRecoveringPendingPurchases else { return }
        isRecoveringPendingPurchases = true
        defer { isRecoveringPendingPurchases = false }
        await processUnfinishedPurchases()
    }

    func applyPurchaseGrantIfNeeded(_ grant: PurchaseGrant) async -> Bool {
        if processedPurchaseTransactionIDs.contains(grant.transactionID) {
            await grant.finish()
            return true
        }

        guard !processingPurchaseTransactionIDs.contains(grant.transactionID) else {
            return false
        }

        processingPurchaseTransactionIDs.insert(grant.transactionID)
        defer {
            processingPurchaseTransactionIDs.remove(grant.transactionID)
        }

        do {
            let updatedCredits = try await syncPurchase(grant)
            remainingCredits = updatedCredits
            persistCredits()
            processedPurchaseTransactionIDs.insert(grant.transactionID)
            defaults.set(
                Array(processedPurchaseTransactionIDs),
                forKey: AppStorageKey.processedPurchaseTransactions
            )
            purchaseErrorMessage = nil
            await grant.finish()
            return true
        } catch {
            if let applicationError = error as? PurchaseGrantApplicationError {
                purchaseErrorMessage = applicationError.localizedDescription
            } else {
                purchaseErrorMessage = "购买已完成，但次数同步失败。请保持网络连接后重新打开应用重试。"
            }
            return false
        }
    }

    private func preparePurchaseSession() async throws -> SupabaseSession {
        if isRestoringAuthenticatedSession {
            await ensureRemoteSessionRestoreCompleted()
        }

        guard !isRestoringAuthenticatedSession else {
            throw PurchaseGrantApplicationError.accountRestoreInProgress
        }

        let session = try await ensureValidSession()
        guard session.isAnonymous || profile != nil else {
            throw PurchaseGrantApplicationError.authenticatedProfileUnavailable
        }
        _ = try purchaseAppAccountToken(for: session)
        return session
    }

    private func validatedSession(for grant: PurchaseGrant) async throws -> SupabaseSession {
        guard let appAccountToken = grant.appAccountToken else {
            throw PurchaseGrantApplicationError.missingAppAccountToken
        }

        let session = try await preparePurchaseSession()
        guard appAccountToken.uuidString.lowercased() == session.userID.lowercased() else {
            throw PurchaseGrantApplicationError.appAccountTokenMismatch
        }

        return session
    }

    private func purchaseAppAccountToken(for session: SupabaseSession) throws -> UUID {
        guard let token = UUID(uuidString: session.userID) else {
            throw PurchaseGrantApplicationError.invalidPurchaseSession
        }

        return token
    }

    func startObservingPurchaseTransactionsIfNeeded() {
        guard !hasStartedObservingPurchaseTransactions else { return }
        hasStartedObservingPurchaseTransactions = true

        purchaseManager.startObservingTransactionUpdates { [weak self] grant in
            _ = await self?.applyPurchaseGrantIfNeeded(grant)
        }
    }
}
