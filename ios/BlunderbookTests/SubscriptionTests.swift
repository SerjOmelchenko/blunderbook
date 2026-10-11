//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import StoreKit
import StoreKitTest
import XCTest
@testable import Blunderbook

/// Drives the real StoreKit 2 paths against the bundled configuration, so the product identifier
/// and the free-to-premium transition are verified rather than assumed.
@MainActor
final class SubscriptionTests: XCTestCase {

    private var session: SKTestSession!
    private var database: SQLiteDatabase!
    private var preferences: PreferencesRepository!
    private var temporaryDirectory: URL!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "USA"

        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: temporaryDirectory.appendingPathComponent("t.sqlite").path)
        try Schema.migrate(database)
        preferences = PreferencesRepository(database: database)
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - The product

    func testTheConfiguredProductMatchesAppStoreConnect() async throws {
        let products = try await Product.products(for: [EntitlementService.productID])
        let product = try XCTUnwrap(products.first, "no product for id \(EntitlementService.productID)")

        XCTAssertEqual(product.id, "monthly_premium")
        XCTAssertEqual(product.type, .autoRenewable)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(product.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(product.isFamilyShareable, false, "Family Sharing is off, per §3")
    }

    func testThePriceComesFromStoreKitRatherThanBeingHardCoded() async {
        let service = EntitlementService(preferences: preferences)
        await service.loadProduct()

        let product = try? XCTUnwrap(service.product)
        XCTAssertNotNil(product)
        XCTAssertFalse(service.productLoadFailed)
        // Whatever the storefront says, not a literal in the source.
        XCTAssertEqual(service.priceDescription, "\(service.product!.displayPrice) / month")
        XCTAssertFalse(service.priceDescription.contains("$5"))
    }

    // MARK: - Free trial

    /// Read from the bundled configuration itself: StoreKit may answer from the App Store
    /// sandbox instead, where the offer has to be set up in App Store Connect to match.
    func testTheConfigurationOffersASevenDayFreeTrial() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Products", withExtension: "storekit"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        let subscription = try XCTUnwrap(groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
            .first { $0["productID"] as? String == EntitlementService.productID })
        let offer = try XCTUnwrap(subscription["introductoryOffer"] as? [String: Any], "no introductory offer")
        XCTAssertEqual(offer["paymentMode"] as? String, "free")
        XCTAssertEqual(offer["subscriptionPeriod"] as? String, "P1W")
        XCTAssertEqual(subscription["recurringSubscriptionPeriod"] as? String, "P1M")
    }

    /// Subscribing starts the trial, which is full access, and can only be had once.
    func testStartingTheTrialIsPremiumAndUsesItUp() async throws {
        let service = EntitlementService(preferences: preferences)
        await service.refreshTrialEligibility()
        XCTAssertEqual(service.freeTrialLength, "7-day")
        XCTAssertEqual(service.freeTrialDuration, "7 days")
        let outcome = await service.purchase()
        XCTAssertEqual(outcome, .purchased)
        guard case .trial = service.state else { return XCTFail("expected the trial, got \(service.state)") }
        XCTAssertTrue(service.state.isPremium)
        XCTAssertTrue(service.unlocksPremiumFeatures)
        XCTAssertNil(service.freeTrial, "the trial is used up")

        await service.refreshTrialEligibility()
        XCTAssertNil(service.freeTrial, "and stays used up when the App Store is asked again")
    }

    /// Before the App Store answers, a subscription verified earlier keeps screens unlocked, and
    /// nothing else does.
    func testLocksWaitForTheAppStoreOnlyForAKnownSubscriber() {
        let service = EntitlementService(preferences: preferences)
        XCTAssertEqual(service.state, .unknown)
        XCTAssertFalse(service.unlocksPremiumFeatures, "never subscribed")

        preferences.set(PreferenceKey.entitlementValidThrough,
                        ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400)))
        XCTAssertTrue(service.unlocksPremiumFeatures, "subscribed, still inside the period")

        preferences.set(PreferenceKey.entitlementValidThrough,
                        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400)))
        XCTAssertFalse(service.unlocksPremiumFeatures, "the period has passed")
    }

    // MARK: - Free to premium

    /// Premium is what unlocks analysing all games at once. Single games and the whole history
    /// are on every plan, so the scope never changes with the subscription.
    func testPurchasingGrantsPremiumWithoutChangingWhatIsShown() async throws {
        let service = EntitlementService(preferences: preferences)
        await service.loadProduct()
        await service.refreshEntitlement()
        XCTAssertEqual(service.state, .free)
        XCTAssertFalse(service.state.isPremium)
        XCTAssertEqual(service.state.scope, .allDownloaded, "free users see their whole history")

        let outcome = await service.purchase()
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(service.state.isPremium, "state after purchase: \(service.state)")
        XCTAssertEqual(service.state.scope, .allDownloaded)
    }

    /// §3: expired, revoked and refunded access is all free. StoreKit's harness cannot produce a
    /// revocation, so the decision itself is tested directly.
    func testRevokedAndElapsedTransactionsDoNotGrantAccess() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let future = now.addingTimeInterval(86_400)
        let past = now.addingTimeInterval(-86_400)

        XCTAssertTrue(EntitlementService.grantsAccess(expirationDate: future, revocationDate: nil, now: now))
        XCTAssertTrue(EntitlementService.grantsAccess(expirationDate: nil, revocationDate: nil, now: now),
                      "a non-expiring purchase grants access")

        XCTAssertFalse(EntitlementService.grantsAccess(expirationDate: past, revocationDate: nil, now: now),
                       "an elapsed period is not access")
        XCTAssertFalse(EntitlementService.grantsAccess(expirationDate: future, revocationDate: past, now: now),
                       "a refund or revocation ends access even inside a paid period")
        XCTAssertFalse(EntitlementService.grantsAccess(expirationDate: nil, revocationDate: past, now: now))
        XCTAssertFalse(EntitlementService.grantsAccess(expirationDate: now, revocationDate: nil, now: now),
                       "the boundary counts as elapsed")
    }

    func testAnExpiredPeriodStillCountsWhileTheSubscriptionRenews() async throws {
        let service = EntitlementService(preferences: preferences)
        await service.loadProduct()
        _ = await service.purchase()

        // Expiring the current period makes StoreKit renew it. Access must continue, because the
        // subscription is still active — this is the case that must *not* be read as expiry.
        try session.expireSubscription(productIdentifier: EntitlementService.productID)
        await service.refreshEntitlement()
        XCTAssertTrue(service.state.isPremium)
        XCTAssertNotNil(service.state.validThrough)
    }

    func testRevokingRemovesPremium() async throws {
        let service = EntitlementService(preferences: preferences)
        await service.loadProduct()
        _ = await service.purchase()
        XCTAssertTrue(service.state.isPremium)

        session.clearTransactions()
        service.clearCachedEntitlement()
        await service.refreshEntitlement()
        XCTAssertFalse(service.state.isPremium)
    }

    func testACancelledPurchaseChangesNothing() async throws {
        session.failTransactionsEnabled = true
        session.failureError = .paymentCancelled

        let service = EntitlementService(preferences: preferences)
        await service.loadProduct()
        let outcome = await service.purchase()

        switch outcome {
        case .cancelled, .failed:
            break  // Either is acceptable; what matters is that nothing was granted.
        default:
            XCTFail("expected the purchase to be refused, got \(outcome)")
        }
        XCTAssertFalse(service.state.isPremium)
    }

    // MARK: - Offline

    func testACachedEntitlementCarriesPremiumThroughItsValidThroughDate() async throws {
        // Written by a previous verified purchase, then read back with no StoreKit transaction.
        let future = Date().addingTimeInterval(7 * 86_400)
        preferences.set(PreferenceKey.entitlementValidThrough,
                        ISO8601DateFormatter().string(from: future))

        let service = EntitlementService(preferences: preferences)
        await service.refreshEntitlement()
        XCTAssertTrue(service.state.isPremium, "a known-good period is honoured offline")

        // And expires with it, rather than lasting for ever.
        preferences.set(PreferenceKey.entitlementValidThrough,
                        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400)))
        await service.refreshEntitlement()
        XCTAssertEqual(service.state, .free)
    }
}
