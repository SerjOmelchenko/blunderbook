//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI
import StoreKit

/// The app's pages on the web.
enum SiteLink {
    static let terms = URL(string: "https://serhiiomelchenko.com/blunderbook-app/terms/")!
    static let privacy = URL(string: "https://serhiiomelchenko.com/blunderbook-app/privacy/")!
    static let source = URL(string: "https://serhiiomelchenko.com/blunderbook-app/source/")!
}

// MARK: - W16 Premium plan

struct PaywallScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: PurchaseOutcome?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\u{265B}")
                            .font(.system(size: 48))
                            .foregroundStyle(Palette.brass)
                            .accessibilityHidden(true)
                        Text("Premium")
                            .eyebrowStyle()
                        Text("Every feature,\none plan.")
                            .font(.display(.largeTitle))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let offer = offerLine {
                            Text(offer)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Palette.brass)
                        }
                    }

                    Panel {
                        VStack(spacing: 0) {
                            comparisonRow("Analyse a game you open", free: "Yes", premium: "Yes")
                            Hairline()
                            comparisonRow("Mistakes tab and puzzles", free: "No", premium: "Yes")
                            Hairline()
                            comparisonRow("Review depth", free: "Up to \(ReviewDepth.deepestFree.title)",
                                          premium: "Up to \(ReviewDepth.deepest.title)")
                            Hairline()
                            comparisonRow("Tracked players", free: "\(FreePlan.maxPlayers)", premium: "Unlimited")
                            Hairline()
                            comparisonRow("Analysed games", free: "Kept for good", premium: "Kept for good")
                        }
                    }

                    if let outcome { PurchaseOutcomeBanner(outcome: outcome) }

                    VStack(spacing: 10) {
                        Button {
                            Task { await purchase() }
                        } label: {
                            if isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text(purchaseTitle)
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isWorking || model.entitlement.product == nil)

                        Button("Restore purchases") {
                            Task {
                                isWorking = true
                                let restored = await model.entitlement.restore()
                                isWorking = false
                                outcome = restored ? .purchased : .failed("No active subscription was found for this Apple Account.")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if let length = model.entitlement.freeTrialLength {
                            Text("The \(length) free trial turns into the monthly plan at \(model.entitlement.priceDescription) unless you cancel at least 24 hours before it ends. Nothing is charged during the trial.")
                        }
                        Text("Billed through your Apple Account and renews monthly until cancelled. Manage or cancel it in Settings on this device. Restoring a purchase restores access, not your local games or reviews.")
                        Text("Prices are shown by the App Store in your local currency.")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        Link("Terms", destination: SiteLink.terms)
                        Link("Privacy", destination: SiteLink.privacy)
                    }
                    .font(.footnote.weight(.medium))
                }
                .padding(Layout.gutter)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Not now") { dismiss() } } }
            .task { await model.entitlement.refreshTrialEligibility() }
        }
    }

    private var purchaseTitle: String {
        guard model.entitlement.product != nil else { return "Subscription unavailable" }
        if let length = model.entitlement.freeTrialLength { return "Start \(length) free trial" }
        return "Subscribe · \(model.entitlement.priceDescription)"
    }

    /// "Free for 7 days, then $4.99 / month", or just the price once the trial is used.
    private var offerLine: String? {
        guard model.entitlement.product != nil else { return nil }
        guard let duration = model.entitlement.freeTrialDuration else { return model.entitlement.priceDescription }
        return "Free for \(duration), then \(model.entitlement.priceDescription)"
    }

    private func comparisonRow(_ title: String, free: String, premium: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(free)
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 92, alignment: .trailing)
            Text(premium)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    private func purchase() async {
        isWorking = true
        outcome = await model.purchasePremium()
        isWorking = false
        if case .purchased = outcome { dismiss() }
    }
}

/// What came of a purchase, said the same way wherever Premium is sold.
struct PurchaseOutcomeBanner: View {
    let outcome: PurchaseOutcome

    var body: some View {
        switch outcome {
        case .purchased:
            InfoBanner(title: "Premium is active",
                       message: "Mistakes, the deepest reviews and unlimited players are unlocked.",
                       tone: .success)
        case .pending:
            InfoBanner(title: "Purchase pending", message: "It is waiting for approval. Nothing is lost while it waits.", tone: .info)
        case .cancelled:
            InfoBanner(title: "Purchase cancelled", message: "Nothing was charged and your reviews are untouched.", tone: .info)
        case .failed(let message):
            InfoBanner(title: "Purchase did not complete", message: message, tone: .error)
        case .unavailable:
            InfoBanner(title: "The subscription is not available right now",
                       message: "The product could not be loaded from the App Store. Everything you have already analysed is unaffected.",
                       tone: .warning)
        }
    }
}

/// The plan's terms under a button that buys it, with the Terms and Privacy links: the free
/// trial and what follows it while the account can still have one, the price otherwise.
struct PlanTermsNote: View {
    @Environment(AppModel.self) private var model
    var alignment: TextAlignment = .center

    var body: some View {
        Text(note)
            .font(.caption)
            .foregroundStyle(Palette.inkTertiary)
            .tint(Palette.inkSecondary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var note: AttributedString {
        let entitlement = model.entitlement
        let terms: String
        if let duration = entitlement.freeTrialDuration {
            terms = "Free for \(duration), then \(entitlement.priceDescription). Cancel any time in Settings at least 24 hours before the trial ends."
        } else if entitlement.product != nil {
            terms = "\(entitlement.priceDescription), renews monthly until cancelled."
        } else {
            terms = "Billed monthly through your Apple Account until cancelled."
        }
        let markdown = "\(terms)\n[Terms](\(SiteLink.terms.absoluteString)) · [Privacy](\(SiteLink.privacy.absoluteString))"
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(terms)
    }
}

// MARK: - W17 Subscription

struct SubscriptionScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showPaywall) private var showPaywall
    @State private var isRestoring = false
    @State private var restoreMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current plan").eyebrowStyle()
                        Text(model.entitlement.state.title)
                            .font(.display(.title2))
                            .foregroundStyle(Palette.ink)
                        Text(stateDescription)
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .trial(let trialEnd?) = model.entitlement.state {
                            Text("Free trial ends \(Format.date(trialEnd))")
                                .font(.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        } else if let validThrough = model.entitlement.state.validThrough {
                            Text("Known valid through \(Format.date(validThrough))")
                                .font(.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                    }
                }

                if let restoreMessage {
                    InfoBanner(title: restoreMessage, tone: .info)
                }

                VStack(spacing: 10) {
                    if !model.entitlement.state.isPremium {
                        Button(model.entitlement.freeTrialLength.map { "Start \($0) free trial" } ?? "See the premium plan") { showPaywall() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                        Text("Manage subscription")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
                            .overlay(RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                    Button(isRestoring ? "Restoring\u{2026}" : "Restore purchases") {
                        Task {
                            isRestoring = true
                            let restored = await model.entitlement.restore()
                            isRestoring = false
                            restoreMessage = restored
                                ? "Premium access restored. Local games and reviews are unchanged either way."
                                : "No active subscription was found for this Apple Account."
                            model.coordinator.updateEntitlement(isPremium: model.entitlement.state.isPremium)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isRestoring)
                }

                Text("Subscription status never removes a saved review. When the status cannot be read, everything you already analysed stays exactly where it is.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Layout.gutter)
        }
        .screenBackground()
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.entitlement.refreshEntitlement()
            if !model.entitlement.state.isPremium { await model.entitlement.refreshTrialEligibility() }
        }
    }

    private var stateDescription: String {
        switch model.entitlement.state {
        case .unknown:
            return "The App Store has not answered yet. Saved reviews are unaffected and purchase-dependent work is paused until it does."
        case .free:
            return "Every game you open is analysed in depth, free, at up to \(ReviewDepth.deepestFree.title) depth, for \(FreePlan.playersDescription). Premium adds the Mistakes tab, the \(ReviewDepth.deep.title) and \(ReviewDepth.deepest.title) review depths, and any number of players."
        case .subscribed:
            return "Everything is unlocked: the Mistakes tab, the \(ReviewDepth.deep.title) and \(ReviewDepth.deepest.title) review depths, and any number of players."
        case .trial:
            return "The free trial includes everything Premium does. It becomes the monthly plan when it ends, unless you cancel before then in Manage subscription."
        case .grace:
            return "Access continues while billing is retried, up to the last date verified with the App Store."
        case .pending:
            return "A purchase is waiting for approval."
        }
    }
}
