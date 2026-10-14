//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W12 Mistakes

/// Every error across the player's deep-reviewed games, as something to train on: rings for how
/// the drilling goes and a session button on top, then the biggest leak, the clock and the
/// opening hot spots, each of which narrows the list in place, then the list itself by week.
/// A card opens the mistake as a puzzle; a session drills several in a row. Solved mistakes come
/// back on a schedule (`MistakeSchedule`). A standard analysis labels nothing, so only deep
/// reviews count here.
struct MistakesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var book = MistakeBook.empty
    @State private var reviewedGames = 0
    @State private var hasLoaded = false
    /// The kind the list is narrowed to; nil shows every error.
    @State private var selectedKind: MistakeCategory?
    @State private var focus: MistakeFocus?
    /// The game the list is narrowed to, from `AppModel.mistakesGameKey`.
    @State private var game: GameListEntry?
    @State private var ignored: Ignored?

    private struct Ignored: Equatable {
        var refs: [MistakeRef]
        var text: String
        var id = UUID()
    }

    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                PlayerContextHeader()

                if let game {
                    GameScopePill(entry: game) {
                        withAnimation(.smooth(duration: 0.25)) { model.mistakesGameKey = nil }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if hasLoaded {
                    if reviewedGames == 0 {
                        EmptyState(symbol: "magnifyingglass",
                                   title: "No analysed games in this view",
                                   message: "Tap a game's rings in Games to analyse it in depth. Its mistakes land here, ready to solve.")
                    } else {
                        MistakesContent(book: book, selectedKind: $selectedKind, focus: $focus,
                                        isOneGame: game != nil,
                                        navigate: { model.pendingRoute = $0 },
                                        ignore: ignore)
                    }
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 60)
        }
        .refreshable { await model.refreshSelectedPlayer() }
        .task { await DevelopmentScroll.apply(reader) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let ignored {
                UndoBar(text: ignored.text) { undo(ignored) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: ignored.id) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.smooth(duration: 0.3)) { if self.ignored?.id == ignored.id { self.ignored = nil } }
                    }
            }
        }
        .task(id: taskKey) { load() }
    }

    private var taskKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(model.filters)|\(model.scope.rawValue)|\(model.dataVersion)|\(model.coordinator.counts.completed)|\(model.mistakesGameKey ?? "")|\(model.mistakesKind?.id ?? "")"
    }

    // MARK: Loading

    private func load() {
        guard let player = model.selectedPlayer else { return }
        // Opened from a review's repeat count: narrowed to that kind of mistake.
        if let kind = model.mistakesKind {
            model.mistakesKind = nil
            selectedKind = kind
            focus = nil
        }
        // A game that has gone since, with a changed history or another player, drops the narrowing.
        let gameKey = model.mistakesGameKey
        game = gameKey.flatMap { try? model.games.entry(playerID: player.id, gameKey: $0) }
        if gameKey != nil, game == nil { model.mistakesGameKey = nil; return }
        let games = (try? model.statistics.errorBreakdown(playerID: player.id, filters: model.filters, scope: model.scope,
                                                           gameKey: gameKey))?.games ?? 0
        let occurrences = (try? model.mistakeBook.occurrences(playerID: player.id, filters: model.filters,
                                                              scope: model.scope, gameKey: gameKey)) ?? []
        let loaded = MistakeBook(occurrences: occurrences)
        // A narrowing that no longer has errors cannot stay.
        let kind = selectedKind.flatMap { selected in loaded.backlog.kinds.contains { $0.category == selected } ? selected : nil }
        let keptFocus = focus.flatMap { loaded.count($0) > 0 && gameKey == nil ? $0 : nil }
        // A mistake solved a moment ago gets its check with a little spring.
        withAnimation(hasLoaded ? .spring(response: 0.45, dampingFraction: 0.8) : nil) {
            reviewedGames = games
            book = loaded
            selectedKind = kind
            focus = keptFocus
            hasLoaded = true
        }
    }

    // MARK: Ignoring

    private func ignore(_ occurrence: MistakeOccurrence) {
        let refs = [occurrence.ref] + occurrence.repeats
        try? model.mistakeBook.setIgnored(refs, true)
        withAnimation(.smooth(duration: 0.3)) {
            ignored = Ignored(refs: refs, text: "Ignored \(occurrence.moveNumberLabel) \(occurrence.san)")
        }
        model.touch()
    }

    private func undo(_ ignored: Ignored) {
        try? model.mistakeBook.setIgnored(ignored.refs, false)
        withAnimation(.smooth(duration: 0.3)) { self.ignored = nil }
        model.touch()
    }
}

/// The tab below the player: the session header (or all clear), the biggest leak, the clock,
/// the openings, the kinds, and the list by week. Shared by the tab and by its preview on the
/// free plan, which feeds it sample games.
struct MistakesContent: View {
    let book: MistakeBook
    @Binding var selectedKind: MistakeCategory?
    @Binding var focus: MistakeFocus?
    /// Narrowed to one game: the figures and the empty state speak of that game.
    var isOneGame = false
    var navigate: (Route) -> Void
    /// Nil where mistakes cannot be ignored, as in the preview.
    var ignore: ((MistakeOccurrence) -> Void)?

    @State private var limit = MistakesContent.pageSize
    private static let pageSize = 60

    private var shown: [MistakeOccurrence] { book.shown(kind: selectedKind, focus: focus) }
    /// Changes whenever the list is drawn afresh, so its cards rise in again.
    private var listKey: String { "\(selectedKind?.id ?? "all")|\(String(describing: focus))" }

    var body: some View {
        if book.errors == 0 {
            AllClearPanel(title: isOneGame ? "No errors in this game" : "No errors in this view",
                          message: isOneGame ? "Nothing to solve here." : "Within the current player, filters and plan scope.")
        } else {
            header
            LeakPanel(book: book, selectedKind: $selectedKind, showsTrend: !isOneGame)
                .id("mistakes-leak")
            if book.time.timed > 0 {
                ClockPanel(time: book.time, focus: $focus)
            }
            if !isOneGame, !book.hotSpots.isEmpty || book.repeatedCount > 0 {
                HotSpotsPanel(spots: book.hotSpots, repeated: book.repeatedCount, focus: $focus)
            }
            KindChipRow(book: book, selected: $selectedKind, showsTrend: !isOneGame)
                .id("mistakes-kinds")
            if let focus {
                FocusPill(focus: focus, count: shown.count) {
                    withAnimation(.smooth(duration: 0.3)) { self.focus = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let selectedKind {
                Text(selectedKind.detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .id(selectedKind.id)
            }
            list
        }
    }

    @ViewBuilder
    private var header: some View {
        if book.isAllClear {
            AllClearPanel(title: "All clear", message: allClearMessage)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            TrainingHeader(book: book) { pick in navigate(.training(pick)) }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    private var allClearMessage: String {
        guard let next = book.nextReview else { return "Every mistake here is learned." }
        let puzzles = "\(next.count) puzzle\(next.count == 1 ? "" : "s")"
        return "Nothing due. \(puzzles) come\(next.count == 1 ? "s" : "") back in \(MistakeState.days(until: next.date))."
    }

    @ViewBuilder
    private var list: some View {
        let items = Array(shown.prefix(limit))
        if items.isEmpty {
            Text("No errors match.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        ForEach(isOneGame ? [MistakeBook.Section(start: .distantPast, title: "This game", items: items)] : book.sections(items)) { section in
            Section {
                VStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, occurrence in
                        if index > 0 { Hairline().padding(.leading, 100) }
                        row(occurrence)
                            .modifier(RiseIn(index: rank(of: occurrence, in: items)))
                            .transition(.asymmetric(insertion: .opacity,
                                                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
                    }
                }
                .background(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous).fill(Palette.surface))
                .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
            } header: {
                MistakeSectionHeader(section: section)
            }
        }
        .id(listKey)
        if shown.count > limit {
            Button("Show more") { withAnimation(.smooth(duration: 0.3)) { limit += Self.pageSize } }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func rank(of occurrence: MistakeOccurrence, in items: [MistakeOccurrence]) -> Int {
        items.firstIndex { $0.id == occurrence.id } ?? 0
    }

    private func row(_ occurrence: MistakeOccurrence) -> some View {
        SwipeRow(actions: actions(for: occurrence)) {
            Button { navigate(.mistakeDrill(occurrence)) } label: {
                MistakeCard(occurrence: occurrence).padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            ForEach(actions(for: occurrence)) { action in
                Button(action.title, systemImage: action.symbol, action: action.run)
            }
        }
    }

    private func actions(for occurrence: MistakeOccurrence) -> [SwipeAction] {
        var actions: [SwipeAction] = []
        if ignore != nil {
            actions.append(.init(title: "Open game", symbol: "arrow.up.forward.square", tint: Palette.brand) {
                navigate(.gameReview(gameKey: occurrence.gameKey, ply: occurrence.ply))
            })
        }
        if let ignore {
            actions.append(.init(title: "Ignore", symbol: "eye.slash", tint: Palette.inkSecondary) {
                withAnimation(.smooth(duration: 0.35)) { ignore(occurrence) }
            })
        }
        return actions
    }
}

/// Development only: opens the tab scrolled to one part (`-scroll-to`), for screenshots.
enum DevelopmentScroll {
    @MainActor
    static func apply(_ reader: ScrollViewProxy) async {
        #if DEBUG
        guard let target = DevelopmentSeed.scrollTarget else { return }
        try? await Task.sleep(for: .milliseconds(900))
        reader.scrollTo(target, anchor: .top)
        #endif
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
