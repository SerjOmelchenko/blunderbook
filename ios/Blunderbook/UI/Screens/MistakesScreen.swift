//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W12 Mistakes

/// Every error across the player's deep-reviewed games in one list, newest first. Each card
/// carries labels saying what kind of mistake it was and opens it as a puzzle; a solved one
/// carries a green check. The labels above the list narrow it to one kind in place — there is no
/// screen per kind. A standard analysis labels nothing, so only deep reviews count here.
struct MistakesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var breakdown = ErrorBreakdown()
    @State private var backlog = MistakeBacklog()
    @State private var accuracy: Double?
    @State private var mistakes: [MistakeOccurrence] = []
    /// The kind the list is narrowed to; nil shows every error.
    @State private var selectedKind: MistakeCategory?
    /// The game the list is narrowed to, from `AppModel.mistakesGameKey`.
    @State private var game: GameListEntry?

    private static let pageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlayerContextHeader()

                if let game {
                    GameScopePill(entry: game) {
                        withAnimation(.smooth(duration: 0.25)) { model.mistakesGameKey = nil }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if breakdown.games == 0 {
                    EmptyState(symbol: "magnifyingglass",
                               title: "No analysed games in this view",
                               message: "Open any game and it is analysed in depth. Its mistakes land here, ready to solve.")
                } else {
                    MistakesContent(breakdown: breakdown, backlog: backlog, accuracy: accuracy,
                                    mistakes: mistakes, selectedKind: $selectedKind, isOneGame: game != nil,
                                    canShowMore: mistakes.count >= Self.pageSize && mistakes.count % Self.pageSize == 0,
                                    showMore: loadMore)
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 60)
        }
        .refreshable { await model.refreshSelectedPlayer() }
        .task(id: taskKey) { load() }
    }

    private var taskKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(model.filters)|\(model.scope.rawValue)|\(model.dataVersion)|\(model.coordinator.counts.completed)|\(selectedKind?.id ?? "all")|\(model.mistakesGameKey ?? "")"
    }

    // MARK: Loading

    /// Reloads as many as are on screen, so solving one deep in the list keeps the place.
    private func load() {
        guard let player = model.selectedPlayer else { return }
        // A game that has gone since, with a changed history or another player, drops the narrowing.
        let gameKey = model.mistakesGameKey
        game = gameKey.flatMap { try? model.games.entry(playerID: player.id, gameKey: $0) }
        if gameKey != nil, game == nil { model.mistakesGameKey = nil; return }
        breakdown = (try? model.statistics.errorBreakdown(playerID: player.id, filters: model.filters, scope: model.scope,
                                                          gameKey: gameKey)) ?? ErrorBreakdown()
        accuracy = (try? model.statistics.averageAccuracy(playerID: player.id, filters: model.filters, scope: model.scope,
                                                          gameKey: gameKey)) ?? nil
        let loadedBacklog = (try? model.statistics.mistakeBacklog(playerID: player.id, filters: model.filters, scope: model.scope,
                                                                   gameKey: gameKey)) ?? MistakeBacklog()
        // A kind that no longer has errors cannot stay selected.
        let kind = selectedKind.flatMap { selected in loadedBacklog.kinds.contains { $0.category == selected } ? selected : nil }
        let loaded = (try? model.statistics.occurrences(playerID: player.id, filters: model.filters, scope: model.scope,
                                                        category: kind, gameKey: gameKey,
                                                        limit: max(Self.pageSize, mistakes.count))) ?? []
        // A mistake solved a moment ago gets its check with a little spring.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            backlog = loadedBacklog
            selectedKind = kind
            mistakes = loaded
        }
    }

    private func loadMore() {
        guard let player = model.selectedPlayer else { return }
        let more = (try? model.statistics.occurrences(playerID: player.id, filters: model.filters, scope: model.scope,
                                                      category: selectedKind, gameKey: model.mistakesGameKey,
                                                      offset: mistakes.count)) ?? []
        mistakes.append(contentsOf: more)
    }
}

/// The backlog itself: the summary tiles, the kinds to narrow by and the list. Shared by the tab
/// and by its preview on the free plan, which feeds it sample games.
struct MistakesContent: View {
    let breakdown: ErrorBreakdown
    let backlog: MistakeBacklog
    let accuracy: Double?
    /// Already narrowed to `selectedKind`.
    let mistakes: [MistakeOccurrence]
    @Binding var selectedKind: MistakeCategory?
    /// Narrowed to one game: the figures and the empty state speak of that game.
    var isOneGame = false
    var canShowMore = false
    var showMore: () -> Void = {}

    var body: some View {
        summaryTiles
        if backlog.errors == 0 {
            EmptyState(symbol: "checkmark.circle",
                       title: isOneGame ? "No errors in this game" : "No errors in this view",
                       message: isOneGame ? "Nothing to solve here." : "Within the current player, filters and plan scope.")
        } else {
            kindFilter
            mistakeList
        }
    }

    private var summaryTiles: some View {
        StatTileRow {
            StatTile(label: "Errors", value: backlog.errors.formatted(),
                     caption: isOneGame ? "in this game" : "in \(breakdown.games) deep review\(breakdown.games == 1 ? "" : "s")")
            StatTile(label: "Solved", value: backlog.solved.formatted(),
                     caption: "of \(backlog.errors.formatted()) errors",
                     tone: backlog.solved > 0 ? Palette.best : Palette.ink)
            StatTile(label: "Accuracy", value: Format.accuracy(accuracy),
                     caption: isOneGame ? "this game" : "average per game", ring: accuracy)
        }
    }

    // MARK: Kinds

    /// One row of labels, each with its count: tapping one narrows the list to that kind, and
    /// tapping it again, or All, shows everything.
    private var kindFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                kindChip(title: "All", count: backlog.errors, isSelected: selectedKind == nil) {
                    selectedKind = nil
                }
                ForEach(backlog.kinds) { kind in
                    kindChip(title: kind.category.title, count: kind.count,
                             isSelected: selectedKind == kind.category) {
                        selectedKind = selectedKind == kind.category ? nil : kind.category
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
        }
        .padding(.horizontal, -Layout.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kinds of mistake")
    }

    private func kindChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Palette.onBrand.opacity(0.7) : Palette.inkTertiary)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? Palette.onBrand : Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Capsule().fill(isSelected ? Palette.brand : Color.white.opacity(0.07)))
            .frame(minHeight: Layout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: List

    @ViewBuilder
    private var mistakeList: some View {
        if let selectedKind {
            Text(selectedKind.detail)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Panel(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(mistakes.enumerated()), id: \.element.id) { index, occurrence in
                    if index > 0 { Hairline().padding(.leading, 16) }
                    NavigationLink(value: Route.mistakeDrill(occurrence)) {
                        MistakeCard(occurrence: occurrence).padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if canShowMore {
            Button("Show more", action: showMore)
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// The game Mistakes is narrowed to, with a button that widens it to every game again.
struct GameScopePill: View {
    let entry: GameListEntry
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(entry.outcome.shortLabel) · vs \(entry.opponent.username) · \(Format.relative(entry.game.endTime))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 14)
                .accessibilityLabel("Mistakes from the game against \(entry.opponent.username), \(Format.date(entry.game.endTime))")
            Spacer(minLength: 4)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.brand)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.brand.opacity(0.16)))
                    .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show mistakes from every game")
        }
        .frame(minHeight: Layout.minimumTarget)
        .background(Capsule().fill(Palette.brandSoft))
        .overlay(Capsule().strokeBorder(Palette.brand.opacity(0.35), lineWidth: 1))
    }
}

/// One error: a thumbnail of the position with the move played as a red arrow, the move and
/// its severity, labels for what kind of mistake it was, and a green check once it is solved.
struct MistakeCard: View {
    let occurrence: MistakeOccurrence

    private var thumbnail: BoardPresentation {
        var presentation = BoardPresentation(pieces: ChessBoard(fen: occurrence.fenBefore)?.snapshot
                                                ?? BoardPresentation.empty.pieces,
                                             orientation: occurrence.color)
        presentation.mistakeMove = occurrence.move
        return presentation
    }

    var body: some View {
        HStack(spacing: 12) {
            BoardView(presentation: thumbnail, showsCoordinates: false, cornerRadius: 8)
                .frame(width: 56, height: 56)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(occurrence.moveNumberLabel) \(occurrence.san)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    if let severity = occurrence.severity {
                        Badge(text: severity.label, tone: severity.color)
                    }
                }
                if !occurrence.kinds.isEmpty {
                    MistakeKindLabels(kinds: occurrence.kinds)
                }
                Text("vs \(occurrence.opponent) · \(Format.relative(occurrence.endTime)) · \(occurrence.phase.label)")
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if occurrence.isSolved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.best)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: Layout.minimumTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(occurrence.isSolved ? "Solved" : "Not solved")
        .accessibilityHint("Opens the position to find a better move")
    }
}

/// What kind of mistake a move was. A pattern the board demonstrates is marked as a tactic; a
/// consequence, for a move no pattern explains, is quieter.
struct MistakeKindLabels: View {
    let kinds: [MistakeCategory]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(kinds) { kind in
                HStack(spacing: 3) {
                    Image(systemName: kind.isPattern ? "scope" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(kind.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(kind.isPattern ? .semibold : .regular))
                .foregroundStyle(kind.isPattern ? Palette.brass : Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
