//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - Free-trial offer

/// The one offer of the free trial the app makes by itself: the first time somebody leaves an
/// analysed game that has something to solve, on the free plan, while Apple says the account
/// can still have the trial. It speaks about that game. Shown once per install, whatever is
/// tapped; the Mistakes preview, the plan and Settings › Subscription offer the trial after.
struct TrialOffer: Identifiable, Equatable {
    let gameKey: String
    let opponent: String
    /// "5 min · 2h ago"
    let detail: String
    let accuracy: Double
    let days30: Double?
    let months12: Double?
    let errors: ErrorBreakdown

    var id: String { gameKey }
}

extension AppModel {
    /// The offer for the game just left, or nil when it is not the moment: it has been shown,
    /// the plan is not free, or the game has no review or nothing to solve. A clean game leaves
    /// the offer for a later one. Apple is asked about the trial just before it shows
    /// (`trialIsOnOffer`).
    func trialOffer(afterLeaving gameKey: String) async -> TrialOffer? {
        guard preferences.string(PreferenceKey.trialOfferShown) != "1", entitlement.state == .free,
              let player = selectedPlayer,
              let entry = (try? games.entry(playerID: player.id, gameKey: gameKey)) ?? nil,
              entry.hasDeepReview, let accuracy = entry.accuracy,
              let errors = try? statistics.errorBreakdown(playerID: player.id, filters: filters, scope: scope,
                                                          gameKey: gameKey),
              errors.total > 0 else { return nil }
        return TrialOffer(gameKey: gameKey, opponent: entry.opponent.username,
                          detail: "\(entry.game.timeControlLabel) \u{00B7} \(Format.relative(entry.game.endTime))",
                          accuracy: accuracy, days30: entry.accuracy30Days, months12: entry.accuracy12Months,
                          errors: errors)
    }

    /// Whether Apple still offers this account the free trial, on the free plan.
    func trialIsOnOffer() async -> Bool {
        await entitlement.refreshTrialEligibility()
        #if DEBUG
        // Lets the offer be laid out before the App Store product carries the trial.
        if DevelopmentSeed.assumesTrialEligible { return entitlement.state == .free }
        #endif
        return entitlement.freeTrial != nil && entitlement.state == .free
    }

    /// Called as the offer comes up: it never comes up again.
    func markTrialOfferShown() {
        preferences.set(PreferenceKey.trialOfferShown, "1")
        UsageAnalytics.shared.track(.trialOfferShown)
    }
}

struct TrialOfferSheet: View {
    let offer: TrialOffer

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var outcome: PurchaseOutcome?
    @State private var isAnswered = false
    @State private var contentHeight: CGFloat = 460

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                gameHeader
                Text(headline)
                    .font(.display(.title2))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                counts
                Text("Premium turns each one into a puzzle in Mistakes, and brings it back until it sticks. Try it free for \(model.entitlement.freeTrialDuration ?? "7 days").")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let outcome, outcome != .cancelled { PurchaseOutcomeBanner(outcome: outcome) }

                VStack(spacing: 4) {
                    Button { Task { await purchase() } } label: {
                        if isPurchasing {
                            ProgressView().tint(Palette.onBrand)
                        } else {
                            Text("Start \(model.entitlement.freeTrialLength ?? "7-day") free trial")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isPurchasing || outcome == .purchased || model.entitlement.product == nil)

                    Button("Not now") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
                    .contentShape(Rectangle())
                    .disabled(isPurchasing)
                }
                .padding(.top, 2)

                PlanTermsNote()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Layout.gutter + 4)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surface)
        // As tall as it needs; at large text sizes it becomes a full sheet that scrolls.
        .presentationDetents([.height(contentHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.surface)
        .interactiveDismissDisabled(isPurchasing)
        // "Not now" and swiping the sheet away both count as declining.
        .onDisappear {
            if !isAnswered { UsageAnalytics.shared.track(.trialOfferAnswered(startedTrial: false)) }
        }
    }

    private var gameHeader: some View {
        HStack(spacing: 12) {
            AccuracyRings(phase: .values(game: offer.accuracy, days30: offer.days30, months12: offer.months12,
                                         solved: false),
                          diameter: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.accuracy(offer.accuracy)) accuracy vs \(offer.opponent)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(offer.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let total = offer.errors.total
        return "\(total) \(total == 1 ? "move" : "moves") from this game to solve."
    }

    /// Worst first, leaving out the kinds the game did not have.
    private var counts: some View {
        HStack(spacing: 6) {
            ForEach([Severity.blunder, .mistake, .inaccuracy], id: \.self) { severity in
                let count = offer.errors.count(for: severity)
                if count > 0 {
                    Text("\(count) \(Self.name(severity, count: count))")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(severity.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Palette.surfaceRaised))
                }
            }
        }
    }

    private static func name(_ severity: Severity, count: Int) -> String {
        switch severity {
        case .blunder: return count == 1 ? "blunder" : "blunders"
        case .mistake: return count == 1 ? "mistake" : "mistakes"
        case .inaccuracy: return count == 1 ? "inaccuracy" : "inaccuracies"
        }
    }

    /// On success the banner says so for a moment and the sheet closes on the unlocked app.
    private func purchase() async {
        if !isAnswered { UsageAnalytics.shared.track(.trialOfferAnswered(startedTrial: true)) }
        isAnswered = true
        isPurchasing = true
        outcome = nil
        let result = await model.purchasePremium()
        isPurchasing = false
        withAnimation(.smooth(duration: 0.2)) { outcome = result }
        if result == .purchased {
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        }
    }
}
