//
//  EntitlementStore.swift
//  PokeParty
//
//  Manages the single non-consumable IAP that unlocks pro features
//  (Party Finder, Team Optimizer, Screen Scanner). StoreKit 2 is used
//  throughout: Product.products fetches metadata, transaction verification
//  is handled by the framework, and Transaction.updates keeps the unlock
//  state in sync across devices.
//

import Foundation
import StoreKit

@MainActor
@Observable
final class EntitlementStore {

    static let productID = "com.freebits.pokeparty.pro"

    /// Whether the pro features are currently unlocked.
    #if DEBUG
    private(set) var isUnlocked = true
    #else
    private(set) var isUnlocked = false

    #endif
    /// The StoreKit product — nil until `load()` completes.
    private(set) var product: Product?
    /// True while a purchase sheet is being presented.
    private(set) var isPurchasing = false
    /// Set when a purchase attempt throws an error.
    var purchaseError: String?

    // Started eagerly so no transaction arriving before load() is missed.
    // nonisolated(unsafe) lets deinit cancel it without an actor-isolated access.
    private var updateListenerTask: Task<Void, Never>?

    init() {
        updateListenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    // MARK: - Load

    /// Fetches the product metadata and checks for an existing entitlement.
    /// Call once on app launch (or when the purchases UI is shown).
    func load() async {
        async let productsFetch = try? Product.products(for: [Self.productID])

        // currentEntitlements(for:) is a sequence that yields all current
        // entitlements and then terminates — for a non-consumable this is 0 or 1.
        for await result in Transaction.currentEntitlements(for: Self.productID) {
            await handle(result)
        }

        product = await productsFetch?.first
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product, !isPurchasing else { return }
        isPurchasing = true
        purchaseError = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        isUnlocked = transaction.revocationDate == nil
        await transaction.finish()
    }
}
