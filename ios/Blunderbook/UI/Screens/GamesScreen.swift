//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - Shared row

/// One game on one line: result, opponent, and how well it was played once it has been reviewed.
/// The row itself opens the game; the rings at its end are a separate control (`GameRowRings`).
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

    private var accessibilityText: String {
        var parts = ["\(entry.outcome.label) against \(entry.opponent.username) as \(entry.color.name)",
                     entry.game.timeControlLabel,
                     Format.date(entry.game.endTime)]
        if entry.hasDeepReview {
            parts.append("accuracy \(Format.accuracy(entry.accuracy))")
        } else if entry.isQueued || entry.analysisStatus == .pending || entry.analysisStatus == .running {
            parts.append("analysing")
        } else if entry.analysisStatus == .failed {
            parts.append("analysis failed")
        } else {
            parts.append("not reviewed")
        }
        return parts.joined(separator: ", ")
    }
}

/// The end of a game's row: its accuracy, then the three rings. Grey rings queue a review in
/// place; spinning rings mean it waits or runs; finished rings open the game's mistakes.
struct GameRowRings: View {
    let entry: GameListEntry

    @Environment(AppModel.self) private var model
    @Environment(\.openMistakes) private var openMistakes
    @ScaledMetric(relativeTo: .body) private var figureWidth: CGFloat = 28

    var body: some View {
        if entry.analysisStatus == .failed, !isBusy {
            Text("Failed")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.loss)
                .frame(minHeight: Layout.minimumTarget)
        } else {
            HStack(spacing: 6) {
                Text(figure)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: entry.accuracy ?? 0))
                    .animation(.smooth(duration: 1.1), value: figure)
                    .frame(minWidth: figureWidth, alignment: .trailing)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                Button(action: tap) {
                    AccuracyRings(phase: phase)
                        .frame(minWidth: Layout.minimumTarget, minHeight: Layout.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Not disabled while busy: a disabled button dims, and the spin should stay bright.
                .disabled(phase == .inactive && !model.canAnalyse)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
            }
        }
    }

    private var isBusy: Bool {
        entry.isQueued || entry.analysisStatus == .pending || entry.analysisStatus == .running
    }

    private var phase: AccuracyRings.Phase {
        if isBusy { return .busy }
        if entry.hasDeepReview, let accuracy = entry.accuracy {
            return .values(game: accuracy, days30: entry.accuracy30Days, months12: entry.accuracy12Months,
                           solved: entry.allMistakesSolved)
        }
        return .inactive
    }

    /// Rounded, except that only a perfect game shows 100: 99.6 would otherwise read as flawless.
    private var figure: String {
        guard case .values(let game, _, _, _) = phase else { return "" }
        return "\(game >= 100 ? 100 : min(99, Int(game.rounded())))"
    }

    private func tap() {
        switch phase {
        case .inactive: model.requestReview(gameKey: entry.game.gameKey, deep: true)
        case .values: openMistakes(gameKey: entry.game.gameKey)
        case .busy: break
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .inactive: return "Analyse this game"
        case .busy: return "Analysing"
        case .values(let game, let days30, let months12, let solved):
            var parts = ["Accuracy \(Format.accuracy(game))"]
            if let days30 { parts.append("30 days \(Format.accuracy(days30))") }
            if let months12 { parts.append("12 months \(Format.accuracy(months12))") }
            parts.append(solved ? "every mistake solved" : "\(entry.errorCount - entry.solvedCount) mistakes to solve")
            return parts.joined(separator: ", ")
        }
    }

    private var accessibilityHint: String {
        switch phase {
        case .inactive: return "Starts an in-depth review here"
        case .busy: return ""
        case .values: return "Opens this game's mistakes"
        }
    }
}

/// Rows on the ground, split by hairlines inset to the text. With `onNearEnd`, the list asks
/// for more rows while the last few are still coming into view, so scrolling never stops at a
/// button.
struct GameList: View {
    let entries: [GameListEntry]
    var onNearEnd: (() -> Void)?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                // Two targets side by side, never one inside the other: the row opens the game,
                // the rings act on their own.
                HStack(spacing: 4) {
                    NavigationLink(value: Route.gameReview(gameKey: entry.game.gameKey, ply: nil)) {
                        GameRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    GameRowRings(entry: entry)
                }
                .padding(.leading, Layout.contentInset)
                .padding(.trailing, Layout.contentInset - 6)
                .onAppear {
                    if index >= entries.count - 15 { onNearEnd?() }
                }
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
        var label: String { self == .eligible ? "All games" : "Analysed games" }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.showPaywall) private var showPaywall

    @State private var segment: Segment = .eligible
    @State private var status: ReviewStatusFilter = .all
    @State private var entries: [GameListEntry] = []
    @State private var totalCount = 0
    @State private var hasMore = false
    @State private var showsBulkPreparation = false

    private let pageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    PlayerContextHeader()
                    // Time control is the first thing that decides which games are listed, so it
                    // lives here rather than in Filters; it is shared with Analytics.
                    ChipRow(items: model.timeClasses, title: \.pickerLabel, selection: Binding(
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
                    GameList(entries: entries, onNearEnd: loadMore)

                    if hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .onAppear(perform: loadMore)
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
        .task(id: listKey) { reload() }
        .onChange(of: refreshKey) { _, _ in reload(keepingLoaded: true) }
        .sheet(isPresented: $showsBulkPreparation) { BulkPreparationSheet().hostsPaywall() }
    }

    /// Every game the player has, whatever date range Analytics shows: only the time class,
    /// colour and rating filters narrow this list.
    private var filters: GameFilters { model.filters.ignoringDates }

    /// What the list shows; a change starts it again from the newest game.
    private var listKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(filters)|\(segment.rawValue)|\(status.rawValue)|\(model.scope.rawValue)"
    }

    /// New data for the same list; it reloads in place, keeping every row already scrolled past.
    private var refreshKey: String {
        "\(model.dataVersion)|\(model.coordinator.counts.completed)"
    }

    private var headerLine: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(segment == .eligible ? "\(totalCount.formatted()) games" : "\(totalCount.formatted()) analysed games")
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
                       title: "No analysed games yet",
                       message: "Analyse any game and its review stays here for good.")
        } else if model.selectedPlayer?.status == .offline {
            EmptyState(symbol: "wifi.slash",
                       title: "Offline",
                       message: "Downloaded and analysed games are still here. Pull down to try again.")
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
                PremiumLabel("Analyse previous \(AppModel.bulkBatchSize) games",
                             locked: !model.canAnalyseInBulk)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Loading

    private func reload(keepingLoaded: Bool = false) {
        guard let player = model.selectedPlayer else { entries = []; totalCount = 0; hasMore = false; return }
        totalCount = (try? model.games.pageCount(playerID: player.id, filters: filters, scope: model.scope,
                                                 status: listStatus, savedReviewsOnly: segment == .saved)) ?? 0
        let limit = keepingLoaded ? max(pageSize, entries.count) : pageSize
        let rows = fetch(offset: 0, limit: limit)
        entries = rows
        hasMore = rows.count == limit
    }

    /// The next page, while there is one. Rows arrive in pages of 50 as the end comes into view.
    private func loadMore() {
        guard hasMore else { return }
        let rows = fetch(offset: entries.count, limit: pageSize)
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: rows.filter { !known.contains($0.id) })
        hasMore = rows.count == pageSize
    }

    private var listStatus: ReviewStatusFilter { segment == .eligible ? status : .all }

    private func fetch(offset: Int, limit: Int) -> [GameListEntry] {
        guard let player = model.selectedPlayer else { return [] }
        return (try? model.games.page(playerID: player.id,
                                      filters: filters,
                                      scope: model.scope,
                                      status: listStatus,
                                      savedReviewsOnly: segment == .saved,
                                      limit: limit,
                                      offset: offset)) ?? []
    }
}

// MARK: - W08 Filters

struct FiltersSheet: View {
    /// Games lists every game whatever the dates, so its filters leave the date range out.
    var showsDates = true

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

                if showsDates {
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
                        // Without the dates section, the range Analytics shows stays as it is.
                        draft = GameFilters(timeClass: draft.timeClass,
                                            dateRange: showsDates ? GameFilters.default.dateRange : draft.dateRange)
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
