//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

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
                       caption: "\(reviewCount.formatted()) analysed game\(reviewCount == 1 ? "" : "s")")
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
