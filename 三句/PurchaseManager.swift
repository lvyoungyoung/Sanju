//
//  PurchaseManager.swift
//  三句
//
//  Created by Codex.
//

import Foundation
import StoreKit
import Combine

struct StoreProductConfig {
    let productID: String
    let credits: Int
}

struct StoreProductOffer: Identifiable {
    let product: Product
    let credits: Int

    var id: String { product.id }
}

struct PurchaseGrant {
    let transactionID: String
    let productID: String
    let credits: Int
    let appAccountToken: UUID?
    let finish: @Sendable () async -> Void
}

enum PurchaseError: LocalizedError {
    case noProductsConfigured
    case productNotFound
    case unverified
    case cancelled
    case pending

    var errorDescription: String? {
        switch self {
        case .noProductsConfigured:
            return L10n.string("purchase_error.no_products_configured", "未配置可购买商品。")
        case .productNotFound:
            return L10n.string("purchase_error.product_not_found", "未找到可购买商品。")
        case .unverified:
            return L10n.string("purchase_error.unverified", "支付校验失败，请稍后重试。")
        case .cancelled:
            return L10n.string("purchase_error.cancelled", "你已取消购买。")
        case .pending:
            return L10n.string("purchase_error.pending", "购买正在等待确认，请稍后查看。")
        }
    }
}

@MainActor
final class PurchaseManager: ObservableObject {
    @Published private(set) var offers: [StoreProductOffer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    private var updatesTask: Task<Void, Never>?

    private var configByProductID: [String: StoreProductConfig] {
        Dictionary(uniqueKeysWithValues: Bundle.main.storeProductConfigs.map { ($0.productID, $0) })
    }

    func loadOffers() async throws {
        guard !Bundle.main.storeProductConfigs.isEmpty else {
            offers = []
            throw PurchaseError.noProductsConfigured
        }

        isLoading = true
        defer { isLoading = false }

        let productIDs = Bundle.main.storeProductConfigs.map(\.productID)
        let products = try await Product.products(for: productIDs)

        offers = products.compactMap { product in
            guard let config = configByProductID[product.id] else { return nil }
            return StoreProductOffer(product: product, credits: config.credits)
        }
        .sorted { $0.credits < $1.credits }
    }

    func purchase(productID: String, appAccountToken: UUID) async throws -> PurchaseGrant {
        guard let offer = offers.first(where: { $0.product.id == productID }) else {
            throw PurchaseError.productNotFound
        }

        isPurchasing = true
        defer { isPurchasing = false }

        let options: Set<Product.PurchaseOption> = [
            .appAccountToken(appAccountToken)
        ]

        let result = try await offer.product.purchase(options: options)
        switch result {
        case .success(let verification):
            return try await grant(from: verification)
        case .userCancelled:
            throw PurchaseError.cancelled
        case .pending:
            throw PurchaseError.pending
        @unknown default:
            throw PurchaseError.productNotFound
        }
    }

    func syncUnfinishedPurchases() async -> [PurchaseGrant] {
        var grants: [PurchaseGrant] = []

        for await verification in Transaction.unfinished {
            if let grant = try? await grant(from: verification) {
                grants.append(grant)
            }
        }

        return grants
    }

    func startObservingTransactionUpdates(
        onGrant: @escaping @MainActor (PurchaseGrant) async -> Void
    ) {
        updatesTask?.cancel()
        updatesTask = Task {
            for await verification in Transaction.updates {
                guard let grant = try? await self.grant(from: verification) else { continue }
                await onGrant(grant)
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    private func grant(from verification: VerificationResult<Transaction>) async throws -> PurchaseGrant {
        switch verification {
        case .verified(let transaction):
            guard let config = configByProductID[transaction.productID] else {
                throw PurchaseError.productNotFound
            }

            return PurchaseGrant(
                transactionID: String(transaction.id),
                productID: transaction.productID,
                credits: config.credits,
                appAccountToken: transaction.appAccountToken,
                finish: {
                    await transaction.finish()
                }
            )

        case .unverified:
            throw PurchaseError.unverified
        }
    }
}
