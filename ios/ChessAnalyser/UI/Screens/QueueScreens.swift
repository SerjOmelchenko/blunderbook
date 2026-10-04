//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W14 Bulk preparation

struct BulkPreparationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showPaywall) private var showPaywall
    @State private var plan = AppModel.BulkPlan(eligible: [])
    @State private var alreadyDone = 0
    @State private var queuedCount: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let queuedCount {
                        queuedPanel(queuedCount)
                    } else {
                        header
                        warnings
                        countsPanel
                        estimatePanel
                        startButton
                    }
                }
                .padding(Layout.gutter)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Analyse \(model.filters.timeClass.label.lowercased()) games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(queuedCount == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var header: some View {
        Text("Analyse every \(model.filters.timeClass.label.lowercased()) game\nfor \(model.selectedPlayer?.displayUsername ?? "")")
            .font(.display(.title2))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The two things a person should know before starting: it is genuinely expensive, and it
    /// covers a rolling window rather than all history.
    private var warnings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Everything is calculated on your device and never leaves it. That's why analysing all your games may take hours.")
            Text("We optimise the process so it doesn't overheat your phone or drain the battery. Even so, we recommend running the analysis at home while your phone is connected to a power source.")
            Text("Analysis may slow down or pause if your phone gets too hot or the battery runs low. It resumes automatically once conditions allow.")
        }
        .font(.subheadline)
        .foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var countsPanel: some View {
        Panel {
            VStack(spacing: 0) {
                summaryRow("Games without a review", plan.eligible.count.formatted())
                Hairline()
                summaryRow("Already reviewed, skipped", alreadyDone.formatted())
            }
        }
    }

    @ViewBuilder
    private var estimatePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "How long")
                if model.coordinator.isEstimating {
                    Text("Estimating. The first few games measure this device; until then no duration is promised.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let estimate = model.coordinator.estimatedRemaining {
                    Text(Format.durationRange(estimate))
                        .font(.display(.title3))
                        .foregroundStyle(Palette.ink)
                    Text("Active processing time, not calendar time.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                } else {
                    Text("No estimate yet.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                if model.selectedPlayer?.hasVerifiedWindow == false {
                    Text("History is still downloading, so this count is provisional.")
                        .font(.caption)
                        .foregroundStyle(Palette.brass)
                }
            }
        }
    }

    /// Analysing a whole history in one go is the Premium feature; single games stay free.
    @ViewBuilder
    private var startButton: some View {
        if plan.eligible.isEmpty {
            Text("Every game here already has a review.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
        } else if !model.canAnalyseInBulk {
            VStack(spacing: 8) {
                Button("Analyse all with Premium") { showPaywall() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Any single game you open can be analysed for free.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        } else {
            VStack(spacing: 8) {
                Button("Start analysing \(plan.eligible.count.formatted()) games") {
                    queuedCount = model.startBulk()
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("A single game you open yourself always jumps ahead of this queue.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private func queuedPanel(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(count > 0 ? "Queued \(count.formatted()) games" : "Nothing was queued")
                .font(.display(.title2))
                .foregroundStyle(Palette.ink)
            InfoBanner(title: count > 0 ? "Working through them now" : "Nothing to analyse",
                       message: count > 0
                           ? "You can leave this screen. Progress is saved after every move, and the queue shows what is happening."
                           : "Every game here already has a review.",
                       tone: count > 0 ? .success : .info)
            NavigationLink(value: Route.queue) {
                Text("Open the queue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brand)
            }
        }
    }

    private func load() async {
        plan = model.bulkPlan()
        if let player = model.selectedPlayer {
            let total = (try? model.games.eligibleKeys(playerID: player.id, scope: model.scope,
                                                       timeClass: model.filters.timeClass).count) ?? 0
            alreadyDone = max(0, total - plan.eligible.count)
        }
        await model.coordinator.refreshCounts()
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - W15 Queue

/// Three things only: what the queue is doing and why, how long it has left, and how much space
/// the saved reviews take. Everything else lives in the menu.
struct QueueScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showsCancelConfirmation = false
    @State private var reviewBytes: Int64?
    @State private var reviewCount = 0

    private var coordinator: AnalysisCoordinator { model.coordinator }
    private var counts: QueueCounts { coordinator.counts }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                statusSection
                Hairline()
                figure(title: "Time left", value: timeLeft, caption: timeLeftCaption)
                Hairline()
                figure(title: "Space used by reviews",
                       value: reviewBytes.map(Format.bytes) ?? "—",
                       caption: "\(reviewCount.formatted()) saved review\(reviewCount == 1 ? "" : "s")")
            }
            .padding(.horizontal, Layout.contentInset)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { actionsMenu } }
        .task(id: counts.completed) {
            await coordinator.refreshCounts()
            reviewBytes = try? model.analyses.storageBytes()
            reviewCount = (try? model.analyses.completedCount()) ?? 0
        }
        .confirmationDialog("Cancel all queued analysis?",
                            isPresented: $showsCancelConfirmation,
                            titleVisibility: .visible) {
            Button("Cancel queued work", role: .destructive) {
                try? coordinator.cancelAll()
                model.touch()
            }
            Button("Keep the queue", role: .cancel) {}
        } message: {
            Text("Pending games are removed. Finished reviews are kept.")
        }
    }

    // MARK: Status

    private enum Status {
        case idle(String)
        case working(String)
        case slowed(String)
        case paused(String)

        var title: String {
            switch self {
            case .idle: return "Idle"
            case .working: return "Working"
            case .slowed: return "Slowed down"
            case .paused: return "Paused"
            }
        }

        var detail: String {
            switch self {
            case .idle(let text), .working(let text), .slowed(let text), .paused(let text): return text
            }
        }

        var tone: Color {
            switch self {
            case .idle: return Palette.inkSecondary
            case .working: return Palette.win
            case .slowed: return Palette.brand
            case .paused: return Palette.loss
            }
        }
    }

    private var remaining: Int { counts.pending + counts.running }

    private var status: Status {
        if let engineError = model.engineError {
            return .paused(engineError)
        }
        if remaining == 0 {
            return .idle(counts.completed > 0 ? "Every queued game is analysed." : "Nothing is queued.")
        }
        if coordinator.isPausedByUser {
            return .paused("You paused analysis.")
        }
        if let blocker = coordinator.primaryBlocker {
            return .paused("\(blocker.title). \(blocker.detail)")
        }
        let progress = "\(counts.finished) of \(counts.total) games"
        if coordinator.isPacing {
            let reason = model.conditions.thermalState == .nominal
                ? "The phone got hot earlier, so fewer engines run for a while."
                : "The phone is warm, so analysis runs on its efficiency cores only."
            return .slowed("\(reason) \(progress).")
        }
        if let label = coordinator.currentGameLabel {
            return .working("\(label) · \(progress)")
        }
        return .working(progress)
    }

    private var statusSection: some View {
        let status = status
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(status.tone).frame(width: 10, height: 10)
                Text(status.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Palette.ink)
            }
            .accessibilityElement(children: .combine)
            Text(status.detail)
                .font(.body)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if remaining > 0 {
                CoverageBar(fraction: counts.fraction)
                    .padding(.top, 4)
            }
            if coordinator.isPausedByUser, remaining > 0 {
                Button("Resume") { coordinator.resume() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Figures

    private var timeLeft: String {
        guard remaining > 0 else { return "—" }
        if coordinator.isEstimating { return "Estimating" }
        return coordinator.estimatedRemaining.map { "About \(Format.durationRange($0))" } ?? "—"
    }

    private var timeLeftCaption: String {
        guard remaining > 0 else { return "Nothing left to analyse." }
        if coordinator.isEstimating { return "Measured from the first few games on this phone." }
        return "Time the phone spends analysing; pauses add to it."
    }

    private func figure(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
            Text(value)
                .font(.title.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            if remaining > 0 {
                if coordinator.isPausedByUser {
                    Button("Resume", systemImage: "play.fill") { coordinator.resume() }
                } else {
                    Button("Pause", systemImage: "pause.fill") { coordinator.pause() }
                }
            }
            if counts.failed > 0 {
                Button("Retry \(counts.failed) failed", systemImage: "arrow.clockwise") {
                    try? coordinator.retryFailed()
                }
            }
            if counts.finished > 0 {
                Button("Clear finished", systemImage: "checkmark.circle") {
                    try? coordinator.clearFinished()
                }
            }
            if remaining > 0 {
                Divider()
                Button("Cancel queued work", systemImage: "xmark", role: .destructive) {
                    showsCancelConfirmation = true
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Queue actions")
    }
}
