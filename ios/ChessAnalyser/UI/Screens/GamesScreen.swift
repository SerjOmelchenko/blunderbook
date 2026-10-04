//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - Shared row

/// One game on one line: result, opponent, and how well it was played once it has been reviewed.
struct GameRow: View {
    let entry: GameListEntry

    var body: some View {
        HStack(spacing: 14) {
            Text(entry.outcome.shortLabel)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(entry.outcome.color)
                .frame(width: 20, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.opponent.username)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var meta: String {
        var parts: [String] = []
        if let rating = entry.opponent.rating { parts.append("\(rating)") }
        parts.append(entry.color.name)
        parts.append(entry.game.timeControlLabel)
        parts.append(Format.relative(entry.game.endTime))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if entry.hasCurrentReview {
            VStack(alignment: .trailing, spacing: 6) {
                Text(Format.accuracy(entry.accuracy))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 44, height: 3)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Palette.brand)
                            .frame(width: 44 * CGFloat(min(100, max(0, entry.accuracy ?? 0)) / 100), height: 3)
                    }
            }
        } else if entry.analysisStatus == .failed {
            statusText("Failed", Palette.loss)
        } else if entry.analysisStatus == .running || entry.analysisStatus == .pending {
            statusText("Queued", Palette.brand)
        } else if entry.analysisStatus == .complete, !entry.isCurrentPolicy {
            statusText("Older policy", Palette.inkTertiary)
        } else {
            statusText("Analyse", Palette.inkSecondary)
        }
    }

    private func statusText(_ text: String, _ tone: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tone)
    }

    private var accessibilityText: String {
        var parts = ["\(entry.outcome.label) against \(entry.opponent.username) as \(entry.color.name)",
                     entry.game.timeControlLabel,
                     Format.date(entry.game.endTime)]
        if entry.hasCurrentReview {
            parts.append("accuracy \(Format.accuracy(entry.accuracy)), \(entry.errorCount ?? 0) errors")
        } else {
            parts.append("not reviewed")
        }
        return parts.joined(separator: ", ")
    }
}

/// Rows on the ground, split by hairlines inset to the text.
struct GameList: View {
    let entries: [GameListEntry]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
                NavigationLink(value: Route.gameReview(gameKey: entry.game.gameKey, ply: nil)) {
                    GameRow(entry: entry)
                        .padding(.horizontal, Layout.contentInset)
                }
                .buttonStyle(.plain)
                Hairline().padding(.leading, Layout.contentInset + 34)
            }
        }
    }
}

// MARK: - W07 Games

struct GamesScreen: View {
    enum Segment: String, CaseIterable, Identifiable {
        case eligible, saved
        var id: String { rawValue }
        var label: String { self == .eligible ? "All games" : "Saved reviews" }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.showPaywall) private var showPaywall

    @State private var segment: Segment = .eligible
    @State private var status: ReviewStatusFilter = .all
    @State private var entries: [GameListEntry] = []
    @State private var totalCount = 0
    @State private var isLoadingPage = false
    @State private var showsBulkPreparation = false

    private let pageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    PlayerContextHeader()
                    // Time control is the first thing that decides which games are listed, so it
                    // lives here rather than in Filters; it is shared with Analytics.
                    ChipRow(items: TimeClass.allCases, title: \.label, selection: Binding(
                        get: { model.filters.timeClass },
                        set: { var filters = model.filters; filters.timeClass = $0; model.updateFilters(filters) }
                    ))
                    ChipRow(items: Segment.allCases, title: \.label, selection: $segment)
                }
                .padding(.horizontal, Layout.gutter)

                headerLine
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                if entries.isEmpty {
                    emptyState
                } else {
                    GameList(entries: entries)

                    if entries.count < totalCount {
                        Button {
                            loadMore()
                        } label: {
                            if isLoadingPage { ProgressView() } else { Text("Show \(min(pageSize, totalCount - entries.count)) more") }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .padding(.horizontal, Layout.gutter)
                        .padding(.top, 16)
                    }
                }

                if segment == .eligible, model.canAnalyse {
                    bulkSection
                        .padding(.horizontal, Layout.gutter)
                        .padding(.top, 28)
                }
            }
            .padding(.bottom, 40)
        }
        .refreshable { await model.refreshSelectedPlayer() }
        .task(id: taskKey) { reload() }
        .sheet(isPresented: $showsBulkPreparation) { BulkPreparationSheet() }
    }

    private var taskKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(model.filters)|\(segment.rawValue)|\(status.rawValue)|\(model.scope.rawValue)|\(model.dataVersion)|\(model.coordinator.counts.completed)"
    }

    private var headerLine: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(segment == .eligible ? "\(totalCount.formatted()) games" : "\(entries.count.formatted()) saved reviews")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if let checked = model.selectedPlayer?.lastSuccessfulRefresh {
                    Text("Checked \(Format.relative(checked))")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            Spacer()
            if segment == .eligible {
                Menu {
                    Picker("Show", selection: $status) {
                        ForEach(ReviewStatusFilter.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(status.label)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .glassSurface(in: Capsule(), interactive: true)
                }
                .accessibilityLabel("Show \(status.label) games")
            }
        }
        .frame(minHeight: Layout.minimumTarget)
    }

    @ViewBuilder
    private var emptyState: some View {
        if segment == .saved {
            EmptyState(symbol: "bookmark",
                       title: "No saved reviews yet",
                       message: "Analyse any game and its review stays here for good.")
        } else if model.selectedPlayer?.status == .offline {
            EmptyState(symbol: "wifi.slash",
                       title: "Offline",
                       message: "Cached games and saved reviews are still here. Pull down to try again.")
        } else {
            EmptyState(symbol: "square.grid.3x3",
                       title: "No games in this view",
                       message: "Try another time class, or widen the filters.",
                       actionTitle: "Refresh now") {
                Task { await model.refreshSelectedPlayer() }
            }
        }
    }

    @ViewBuilder
    private var bulkSection: some View {
        let pending = model.coordinator.counts.pending + model.coordinator.counts.running
        if pending > 0 {
            NavigationLink(value: Route.queue) {
                Text("\(pending) game\(pending == 1 ? "" : "s") queued · open queue")
            }
            .buttonStyle(SecondaryButtonStyle())
        } else {
            Button {
                showsBulkPreparation = true
            } label: {
                PremiumLabel("Analyse all \(model.filters.timeClass.label.lowercased()) games",
                             locked: !model.canAnalyseInBulk)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Loading

    private func reload() {
        guard let player = model.selectedPlayer else { entries = []; totalCount = 0; return }
        totalCount = (try? model.games.gameCount(playerID: player.id, filters: model.filters, scope: model.scope)) ?? 0
        entries = fetch(offset: 0)
    }

    private func loadMore() {
        isLoadingPage = true
        defer { isLoadingPage = false }
        entries.append(contentsOf: fetch(offset: entries.count))
    }

    private func fetch(offset: Int) -> [GameListEntry] {
        guard let player = model.selectedPlayer else { return [] }
        return (try? model.games.page(playerID: player.id,
                                      filters: model.filters,
                                      scope: model.scope,
                                      status: segment == .eligible ? status : .all,
                                      savedReviewsOnly: segment == .saved,
                                      limit: pageSize,
                                      offset: offset)) ?? []
    }
}

// MARK: - W08 Filters

struct FiltersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GameFilters.default

    var body: some View {
        NavigationStack {
            Form {
                Section("Colour") {
                    Toggle("Games as White", isOn: binding(for: .white))
                    Toggle("Games as Black", isOn: binding(for: .black))
                }

                Section("Rating") {
                    Toggle("Rated games", isOn: $draft.includeRated)
                    Toggle("Unrated games", isOn: $draft.includeUnrated)
                }

                Section {
                    Picker("Date range", selection: $draft.dateRange) {
                        ForEach(DateRange.displayOrder) { Text($0.longLabel).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Dates")
                } footer: {
                    Text("Filters narrow what you see. They never delete or hide games permanently.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        var applied = draft
                        if applied.colors.isEmpty { applied.colors = [.white, .black] }
                        if !applied.includeRated && !applied.includeUnrated {
                            applied.includeRated = true
                            applied.includeUnrated = true
                        }
                        model.updateFilters(applied)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset to defaults") {
                        draft = GameFilters(timeClass: draft.timeClass)
                    }
                }
            }
            .onAppear { draft = model.filters }
        }
    }

    private func binding(for color: PieceColor) -> Binding<Bool> {
        Binding(get: { draft.colors.contains(color) },
                set: { isOn in
                    if isOn { draft.colors.insert(color) } else { draft.colors.remove(color) }
                    if draft.colors.isEmpty { draft.colors = [color == .white ? .black : .white] }
                })
    }
}
