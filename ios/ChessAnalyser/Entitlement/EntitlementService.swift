//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation
import StoreKit

/// Verified entitlement state (§3). Anything that is not a verified active subscription or a
/// verified grace period is treated as free — billing retry alone is not premium.
enum EntitlementState: Equatable {
    /// Still reading current entitlements. Saved reviews stay visible; purchase-dependent work waits.
    case unknown
    case free
    case subscribed(validThrough: Date?)
    case grace(validThrough: Date?)
    /// The purchase is waiting on approval. Dismissing it is not an error.
    case pending

    var isPremium: Bool {
        switch self {
        case .subscribed, .grace: return true
        case .unknown, .free, .pending: return false
        }
    }

    /// Every plan covers the whole downloaded history; Premium adds bulk analysis, not games.
    var scope: PlanScope { .allDownloaded }

    var title: String {
        switch self {
        case .unknown: return "Checking subscription"
        case .free: return "Free"
        case .subscribed: return "Premium"
        case .grace: return "Premium (billing retry)"
        case .pending: return "Purchase pending"
        }
    }

    var validThrough: Date? {
        switch self {
        case .subscribed(let date), .grace(let date): return date
        default: return nil
        }
    }
}

enum PurchaseOutcome: Equatable {
    case purchased
    case pending
    case cancelled
    case failed(String)
    case unavailable
}

/// StoreKit 2 entitlements with no server of its own.
///
/// One monthly product, read from StoreKit for its localised price and period — the price is
/// never hard-coded. A backup can never grant access, and restoring a purchase restores access,
/// not local data (§3).
@MainActor
@Observable
final class EntitlementService {
    /// The auto-renewable subscription configured in App Store Connect
    /// (group "Premium Subscription", 1 month, Family Sharing off).
    static let productID = "monthly_premium"

    private(set) var state: EntitlementState = .unknown
    private(set) var product: Product?
    private(set) var productLoadFailed = false
    private(set) var lastError: String?

    private let preferences: PreferencesRepository
    private var updatesTask: Task<Void, Never>?

    init(preferences: PreferencesRepository) {
        self.preferences = preferences
    }

    /// Localised price and period straight from StoreKit, or a neutral placeholder while loading.
    var priceDescription: String {
        guard let product else { return productLoadFailed ? "Price unavailable" : "Loading price\u{2026}" }
        let period = product.subscription?.subscriptionPeriod
        let unit: String
        switch period?.unit {
        case .month: unit = period?.value == 1 ? "month" : "\(period?.value ?? 1) months"
        case .year: unit = "year"
        case .week: unit = "week"
        case .day: unit = "day"
        default: unit = "period"
        }
        return "\(product.displayPrice) / \(unit)"
    }

    func start() {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            await self?.loadProduct()
            await self?.refreshEntitlement()
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            productLoadFailed = products.isEmpty
        } catch {
            productLoadFailed = true
            lastError = error.localizedDescription
        }
    }

    /// Reads verified current entitlements. Offline, a previously verified entitlement is honored
    /// only through its known valid-through date (§3).
    func refreshEntitlement() async {
        var resolved: EntitlementState?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == Self.productID else { continue }
            guard Self.grantsAccess(expirationDate: transaction.expirationDate,
                                    revocationDate: transaction.revocationDate) else { continue }
            let expiry = transaction.expirationDate
            resolved = .subscribed(validThrough: expiry)
            if let expiry {
                preferences.set(PreferenceKey.entitlementValidThrough, ISO8601DateFormatter().string(from: expiry))
            }
        }

        if let resolved {
            state = resolved
            return
        }
        // No verified entitlement right now. Fall back to a cached valid-through date so an
        // offline launch does not silently downgrade a paid subscriber mid-period.
        if let text = preferences.string(PreferenceKey.entitlementValidThrough),
           let cached = ISO8601DateFormatter().date(from: text), cached > Date() {
            state = .grace(validThrough: cached)
        } else {
            state = .free
        }
    }

    /// Whether a verified transaction still grants access.
    ///
    /// A refunded or revoked transaction never does, and an elapsed period never does. Extracted
    /// as a pure function because these are the two branches that decide whether somebody keeps
    /// paid access, and StoreKit's test harness cannot drive a revocation.
    static func grantsAccess(expirationDate: Date?, revocationDate: Date?, now: Date = Date()) -> Bool {
        if revocationDate != nil { return false }
        if let expirationDate, expirationDate <= now { return false }
        return true
    }

    func purchase() async -> PurchaseOutcome {
        guard let product else { return .unavailable }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "The purchase could not be verified."
                    return .failed("The purchase could not be verified.")
                }
                await transaction.finish()
                await refreshEntitlement()
                return .purchased
            case .pending:
                state = .pending
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("Unexpected purchase result.")
            }
        } catch {
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Restores access, never local data.
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            return state.isPremium
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func clearCachedEntitlement() {
        preferences.set(PreferenceKey.entitlementValidThrough, nil)
    }
}
