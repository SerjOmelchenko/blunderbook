//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI
import StoreKit

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
                        Text("Analyse every game\nin one go.")
                            .font(.display(.largeTitle))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Panel {
                        VStack(spacing: 0) {
                            comparisonRow("Analyse a game you open", free: "Yes", premium: "Yes")
                            Hairline()
                            comparisonRow("Analyse all games at once", free: "No", premium: "Yes")
                            Hairline()
                            comparisonRow("Tracked players", free: "\(FreePlan.maxPlayers)", premium: "Unlimited")
                            Hairline()
                            comparisonRow("Saved reviews", free: "Kept for good", premium: "Kept for good")
                            Hairline()
                            comparisonRow("Export and import", free: "Yes", premium: "Yes")
                        }
                    }

                    if let outcome { outcomeBanner(outcome) }

                    VStack(spacing: 10) {
                        Button {
                            Task { await purchase() }
                        } label: {
                            if isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text(model.entitlement.product == nil
                                     ? "Subscription unavailable"
                                     : "Subscribe · \(model.entitlement.priceDescription)")
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
                        Text("Billed through your Apple Account and renews monthly until cancelled. Manage or cancel it in Settings on this device. Restoring a purchase restores access, not your local games or reviews.")
                        Text("Prices are shown by the App Store in your local currency.")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        Link("Terms", destination: URL(string: "https://example.com/terms")!)
                        Link("Privacy", destination: URL(string: "https://example.com/privacy")!)
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
            .task { await model.entitlement.loadProduct() }
        }
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

    @ViewBuilder
    private func outcomeBanner(_ outcome: PurchaseOutcome) -> some View {
        switch outcome {
        case .purchased:
            InfoBanner(title: "Premium is active", message: "Bulk analysis and full-history statistics are unlocked.", tone: .success)
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

    private func purchase() async {
        isWorking = true
        outcome = await model.entitlement.purchase()
        isWorking = false
        model.coordinator.updateEntitlement(isPremium: model.entitlement.state.isPremium)
        model.touch()
        if case .purchased = outcome { dismiss() }
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
                        if let validThrough = model.entitlement.state.validThrough {
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
                        Button("See the premium plan") { showPaywall() }
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

                Text("Subscription status never removes a saved review. When the status cannot be read, bulk work simply waits and everything you already analysed stays exactly where it is.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Layout.gutter)
        }
        .screenBackground()
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.entitlement.refreshEntitlement() }
    }

    private var stateDescription: String {
        switch model.entitlement.state {
        case .unknown:
            return "The App Store has not answered yet. Saved reviews are unaffected and purchase-dependent work is paused until it does."
        case .free:
            return "Analyse any game you open, free. Analysing all games at once needs Premium. Up to \(FreePlan.maxPlayers) players."
        case .subscribed:
            return "Analyse all games at once, and track unlimited players."
        case .grace:
            return "Access continues while billing is retried, up to the last date verified with the App Store."
        case .pending:
            return "A purchase is waiting for approval."
        }
    }
}
