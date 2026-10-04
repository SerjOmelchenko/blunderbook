//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W12 Mistakes

struct MistakesScreen: View {
    enum Facet: String, CaseIterable, Identifiable {
        case severity, phase, pattern
        var id: String { rawValue }
        var label: String {
            switch self {
            case .severity: return "Severity"
            case .phase: return "Phase"
            case .pattern: return "Pattern"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var facet: Facet = .severity
    @State private var breakdown = ErrorBreakdown()
    @State private var phases: [PhaseBreakdown] = []
    @State private var tags: [(category: MistakeCategory, count: Int)] = []
    @State private var coverage = AnalyticsCoverage()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlayerContextHeader()

                if !coverage.hasAnalysis {
                    EmptyState(symbol: "chart.bar.doc.horizontal",
                               title: "No completed analyses in this view",
                               message: "This is different from a clean record. Analyse some games and the categories below will fill in.")
                } else {
                    summaryTiles
                    ChipRow(items: Facet.allCases, title: \.label, selection: $facet)
                    categoryList
                    footnotes
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 60)
        }
        .refreshable { await model.refreshSelectedPlayer() }
        .task(id: taskKey) { load() }
    }

    private var taskKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(model.filters)|\(model.scope.rawValue)|\(model.dataVersion)|\(model.coordinator.counts.completed)"
    }

    private var summaryTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where the points\nactually go.")
                .font(.display(.title))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            StatTileRow {
                StatTile(label: "Errors", value: breakdown.total.formatted(),
                         caption: "each move counted once")
                StatTile(label: "Per 100 moves", value: Format.rate(breakdown.ratePer100),
                         caption: "of your analysed moves")
                StatTile(label: "Analysed moves", value: breakdown.analysedMoves.formatted(),
                         caption: "\(coverage.analysedGames) games")
            }
        }
    }

    private var categoryList: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.category.id) { index, row in
                    if index > 0 { Hairline().padding(.leading, 16) }
                    NavigationLink(value: Route.mistakeCategory(row.category)) {
                        DetailRow(title: row.category.title, subtitle: row.subtitle) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(row.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(row.tone)
                                    .monospacedDigit()
                                if let rate = row.rate {
                                    Text("\(Format.rate(rate)) / 100")
                                        .font(.caption2)
                                        .foregroundStyle(Palette.inkTertiary)
                                        .monospacedDigit()
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
                if rows.isEmpty {
                    Text("No errors detected in this view.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .padding(16)
                }
            }
        }
    }

    private struct Row {
        var category: MistakeCategory
        var count: Int
        var rate: Double?
        var subtitle: String
        var tone: Color
    }

    private var rows: [Row] {
        switch facet {
        case .severity:
            return Severity.allCases.sorted { $0.sortOrder < $1.sortOrder }.map { severity in
                let count = breakdown.count(for: severity)
                return Row(category: .severity(severity),
                           count: count,
                           rate: breakdown.analysedMoves > 0 ? Double(count) * 100 / Double(breakdown.analysedMoves) : nil,
                           subtitle: MistakeCategory.severity(severity).detail,
                           tone: severity.color)
            }
        case .phase:
            return phases.map { phase in
                Row(category: .phase(phase.phase),
                    count: phase.errors,
                    rate: phase.ratePer100,
                    subtitle: "\(phase.moves.formatted()) of your moves were in this phase",
                    tone: Palette.ink)
            }
        case .pattern:
            return tags.map { entry in
                Row(category: entry.category,
                    count: entry.count,
                    rate: breakdown.analysedMoves > 0 ? Double(entry.count) * 100 / Double(breakdown.analysedMoves) : nil,
                    subtitle: entry.category.detail,
                    tone: entry.category == .unknownPattern ? Palette.inkSecondary : Palette.brass)
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if facet == .pattern {
                Text("A move can carry more than one pattern, so these counts can add up to more than the number of errors.")
            }
            if facet == .phase {
                Text("Each phase rate uses only your moves in that phase as its denominator.")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        guard let player = model.selectedPlayer else { return }
        breakdown = (try? model.statistics.errorBreakdown(playerID: player.id, filters: model.filters, scope: model.scope)) ?? ErrorBreakdown()
        phases = (try? model.statistics.phaseBreakdown(playerID: player.id, filters: model.filters, scope: model.scope)) ?? []
        tags = (try? model.statistics.tagCounts(playerID: player.id, filters: model.filters, scope: model.scope)) ?? []
        coverage = (try? model.statistics.coverage(playerID: player.id, filters: model.filters, scope: model.scope)) ?? AnalyticsCoverage()
    }
}

// MARK: - W13 Mistake category

struct MistakeCategoryScreen: View {
    @Environment(AppModel.self) private var model
    let category: MistakeCategory
    @State private var occurrences: [MistakeOccurrence] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.title)
                        .font(.display(.title2))
                        .foregroundStyle(Palette.ink)
                    Text(category.detail)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if occurrences.isEmpty && !isLoading {
                    EmptyState(symbol: "checkmark.circle",
                               title: "Nothing in this category",
                               message: "Within the current player, filters and plan scope.")
                } else {
                    Panel(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(occurrences.enumerated()), id: \.element.id) { index, occurrence in
                                if index > 0 { Hairline().padding(.leading, 16) }
                                NavigationLink(value: Route.gameReview(gameKey: occurrence.gameKey, ply: occurrence.ply)) {
                                    occurrenceRow(occurrence).padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if occurrences.count >= 50 {
                        Button("Load more") { loadMore() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Category")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { load() }
    }

    private func occurrenceRow(_ occurrence: MistakeOccurrence) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(occurrence.moveNumberLabel) \(occurrence.san)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    if let severity = occurrence.severity {
                        Badge(text: severity.label, tone: severity.color)
                    }
                }
                Text(occurrence.explanation)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("vs \(occurrence.opponent) · \(Format.relative(occurrence.endTime)) · \(occurrence.phase.label)")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: Layout.minimumTarget)
        .contentShape(Rectangle())
    }

    private func load() {
        guard let player = model.selectedPlayer else { return }
        isLoading = true
        defer { isLoading = false }
        occurrences = (try? model.statistics.occurrences(playerID: player.id,
                                                         filters: model.filters,
                                                         scope: model.scope,
                                                         category: category)) ?? []
    }

    private func loadMore() {
        guard let player = model.selectedPlayer else { return }
        let more = (try? model.statistics.occurrences(playerID: player.id,
                                                      filters: model.filters,
                                                      scope: model.scope,
                                                      category: category,
                                                      offset: occurrences.count)) ?? []
        occurrences.append(contentsOf: more)
    }
}
