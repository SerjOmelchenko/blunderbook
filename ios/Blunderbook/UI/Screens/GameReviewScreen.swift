//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

@MainActor
@Observable
final class GameReviewModel {
    private(set) var entry: GameListEntry?
    private(set) var analysis: GameAnalysis?
    private(set) var moves: [Move] = []
    private(set) var sanMoves: [String] = []
    private(set) var snapshots: [[Piece?]] = []
    private(set) var checkSquares: [Int?] = []
    private(set) var parseError: String?
    /// The last deep review of this game, when it failed.
    private(set) var deepFailure: AnalysisHeader?
    /// Which opening each position had reached, and which moves were book.
    private(set) var openingTrace = OpeningTrace.empty
    /// The game's clock move by move, when its PGN carries one.
    private(set) var clock: GameClock?
    /// Key moments, accuracy by phase and the rest of what a deep review says about the game.
    private(set) var insights = ReviewInsights.empty
    /// The player's results in this game's opening, from two games up.
    private(set) var openingRecord: OpeningRecord?
    /// The book's move where the game left it, numbered: "6. Be2".
    private(set) var theoryMove: String?
    /// For the player's errors with a pattern, by move index: how many times the pattern has come
    /// up in the 30 days up to and including this one, from the second time.
    private(set) var repeatCounts: [Int: Int] = [:]
    private var startFEN = ChessBoard.startFEN
    /// Each move's ring squares, worked out once: the body asks on every redraw.
    @ObservationIgnored private var targetCache: [Int: [Int]] = [:]
    /// The game on screen, so a reload after its analysis finishes keeps the person's place.
    private var loadedKey: String?

    /// Number of moves played: 0 is the starting position, `moves.count` is the final position,
    /// and one more is the summary of a deep review.
    var ply = 0
    var orientation: PieceColor = .white

    var game: GameRecord? { entry?.game }
    var playerColor: PieceColor { entry?.color ?? .white }
    var hasReview: Bool { analysis?.status == .complete }
    var hasDeepReview: Bool { hasReview && analysis?.isDeep == true }

    /// The last place stepping can reach: the summary after a deep review's last move.
    var lastPly: Int { moves.count + (hasDeepReview && !moves.isEmpty ? 1 : 0) }
    var isSummary: Bool { hasDeepReview && !moves.isEmpty && ply == moves.count + 1 }
    /// The position on the board: the final one under the summary.
    var boardPly: Int { min(ply, moves.count) }

    /// The moves of the running review scored so far (`AnalysisEvent.partial`), shown until the
    /// finished review replaces them. Accuracy and the Mistakes backlog wait for the finished one.
    var partial: [MoveAnalysis] = []
    var isShowingPartial: Bool { !hasDeepReview && !partial.isEmpty }
    /// The moves on screen: the running review's while it runs, otherwise the saved review's.
    var shownMoves: [MoveAnalysis] { isShowingPartial ? partial : analysis?.moves ?? [] }
    /// Whether moves carry a deep review's labels, finished or not.
    var showsLabels: Bool { hasDeepReview || isShowingPartial }

    /// The evaluation of the position on screen, when the running review has scored it.
    var partialScore: EngineScore? {
        guard isShowingPartial else { return nil }
        if boardPly == 0 { return partial.first { $0.ply == 0 }?.scoreBefore }
        return currentMove?.scoreAfter
    }

    func load(app: AppModel, gameKey: String, initialPly: Int?) {
        guard let player = app.selectedPlayer else { return }
        entry = (try? app.games.entry(playerID: player.id, gameKey: gameKey)) ?? nil
        analysis = (try? app.analyses.analysis(gameKey: gameKey)) ?? nil
        deepFailure = ((try? app.analyses.header(gameKey: gameKey, policyID: DeepReview.identifier)) ?? nil)
            .flatMap { $0.status == .failed ? $0 : nil }

        guard let game = entry?.game else { return }
        let isReload = loadedKey == gameKey
        loadedKey = gameKey
        // The moves never change; a reload only brings the finished analysis.
        if !isReload || snapshots.isEmpty {
            orientation = entry?.color ?? .white
            let parsed = PGNParser.parse(game.pgn)
            parseError = parsed.parseError
            moves = parsed.moves
            sanMoves = parsed.sanMoves
            startFEN = parsed.startFEN
            clock = GameClock(clocks: parsed.clocks, timeControl: game.timeControl)

            guard let board = ChessBoard(fen: parsed.startFEN) else { return }
            var positions: [[Piece?]] = [board.snapshot]
            var checks: [Int?] = [board.isInCheck ? board.kingSquare(of: board.sideToMove) : nil]
            for move in parsed.moves {
                board.makeMove(move)
                positions.append(board.snapshot)
                checks.append(board.isInCheck ? board.kingSquare(of: board.sideToMove) : nil)
            }
            snapshots = positions
            checkSquares = checks
            openingTrace = OpeningBook.shared.trace(startFEN: parsed.startFEN, moves: parsed.moves)
            theoryMove = bookExitIndex.flatMap { index in
                guard let board = self.board(atPly: index),
                      let move = OpeningBook.shared.theoryMoves(from: board).first else { return nil }
                return EngineLine.notation(for: [move], from: board, maxPlies: 1)
            }
            let record = game.openingName.flatMap { name in
                name.isEmpty ? nil : try? app.statistics.openingRecord(playerID: player.id, openingName: name)
            }
            openingRecord = (record?.games ?? 0) >= 2 ? record : nil

            // A review reads from the start of the game, like a scoresheet. Mistakes stay one tap
            // away through Next key moment; a caller that wants a particular move passes it in.
            if let initialPly {
                ply = min(max(0, initialPly + 1), lastPly)
            } else {
                ply = 0
            }
        }
        refreshInsights(app: app, playerID: player.id, endTime: game.endTime)
    }

    /// What the saved deep review says beyond each move: worked out again whenever it arrives.
    private func refreshInsights(app: AppModel, playerID: UUID, endTime: Date) {
        guard hasDeepReview, let analysis else {
            insights = .empty
            repeatCounts = [:]
            return
        }
        insights = ReviewInsights(moves: analysis.moves, player: playerColor) { self.severity(of: $0) }
        targetCache = [:]
        var counts: [Int: Int] = [:]
        var seen: [PatternTag: Int] = [:]
        var earlier: [PatternTag: Int] = [:]
        for (index, move) in analysis.moves.enumerated() where move.mover == playerColor && severity(of: move) != nil {
            guard let tag = move.labels?.tags.first else { continue }
            if earlier[tag] == nil {
                earlier[tag] = (try? app.statistics.patternCount(playerID: playerID, tag: tag, before: endTime)) ?? 0
            }
            seen[tag, default: 0] += 1
            let total = (earlier[tag] ?? 0) + (seen[tag] ?? 0)
            if total >= 2 { counts[index] = total }
        }
        repeatCounts = counts
    }

    /// The first move off the book, when the game had book moves and then left them.
    var bookExitIndex: Int? {
        let index = openingTrace.bookMoves
        return index > 0 && index < moves.count ? index : nil
    }

    /// Where Explore starts from the position on screen: the real game up to `ply`, with its
    /// history, so repetitions still count in the new line.
    var exploreStart: ExploreStart? {
        guard entry != nil, ChessBoard(fen: startFEN) != nil else { return nil }
        return ExploreStart(startFEN: startFEN,
                            history: Array(moves.prefix(boardPly)),
                            playerColor: playerColor,
                            orientation: orientation,
                            origin: boardPly == 0 ? "From the starting position" : "After \(currentMoveLabel)")
    }

    /// The real position after `ply` moves, with its history, for the live engine lines.
    func board(atPly ply: Int) -> ChessBoard? {
        guard let board = ChessBoard(fen: startFEN) else { return nil }
        for move in moves.prefix(ply) { board.makeMove(move) }
        return board
    }

    // MARK: Derived

    /// The analysed move that produced the current position.
    var currentMove: MoveAnalysis? {
        guard ply > 0, ply <= moves.count else { return nil }
        return shownMoves.first { $0.ply == ply - 1 }
    }

    /// Whether the move at `ply` (0 is White's first move) is shown as a book move: known theory
    /// that the review did not find to be a blunder.
    func isBook(ply: Int) -> Bool {
        guard openingTrace.isBook(ply: ply) else { return false }
        return shownMoves.first { $0.ply == ply }?.severity != .blunder
    }

    /// Whether the move that produced the current position was a book move.
    var isBookMove: Bool { ply > 0 && ply <= moves.count && isBook(ply: ply - 1) }

    /// Whether the move that produced the current position left the book.
    var isBookExit: Bool { bookExitIndex.map { ply == $0 + 1 } ?? false }

    /// The opening as of the current position. The starting position shows the opening the game
    /// went on to reach; a game the book does not know falls back to Chess.com's name for it.
    var currentOpening: Opening? {
        if let opening = boardPly == 0 ? openingTrace.opening : openingTrace.opening(afterPlies: boardPly) {
            return opening
        }
        guard openingTrace.opening == nil, let name = game?.openingName, !name.isEmpty else { return nil }
        return Opening(eco: game?.eco ?? "", name: name)
    }

    /// A deep review's label for a move, with the book's rule applied: reviews made before the
    /// book was added may still label a book move.
    func severity(of move: MoveAnalysis) -> Severity? {
        Scoring.severity(move.severity, isBook: openingTrace.isBook(ply: move.ply))
    }

    func isError(_ move: MoveAnalysis) -> Bool { severity(of: move) != nil }

    /// What kind of mistake a move was, as Mistakes names it: its first pattern, or its
    /// consequence when no pattern explains it.
    func kindLabel(of move: MoveAnalysis) -> String? {
        guard let labels = move.labels else { return nil }
        return MistakeCategory.kinds(tags: labels.tags, consequence: labels.consequence).first?.title
    }

    /// What the lines panel says about the move on screen, when it is worth stopping at.
    var verdict: ReviewVerdict? {
        guard hasDeepReview, let move = currentMove else { return nil }
        let index = move.ply
        if move.mover == playerColor, let severity = severity(of: move), let labels = move.labels {
            let (number, whiteToMove) = Self.turn(fen: move.fenBefore)
            return .error(severity,
                          kind: kindLabel(of: move),
                          spent: clock?.spent[safe: index] ?? nil,
                          missedChance: insights.moments[index] == .missedChance,
                          repeatCount: repeatCounts[index],
                          best: .init(score: move.scoreBefore,
                                      notation: Self.notation(labels.bestLineSAN, fullmove: number, whiteToMove: whiteToMove)),
                          punish: .init(score: move.scoreAfter,
                                        notation: Self.notation(move.lineSAN, fullmove: whiteToMove ? number : number + 1,
                                                                whiteToMove: !whiteToMove)))
        }
        if move.mover != playerColor, let severity = severity(of: move) {
            // "No forcing line" says nothing about the opponent's move; their chance needs a pattern.
            let kind = move.labels.flatMap { $0.tags.first }.map(\.label)
            return .chance(severity, kind: kind)
        }
        if insights.moments[index] == .punished {
            let taken = shownMoves.first { $0.ply == index - 1 }
            return .punished(kind: taken.flatMap(kindLabel(of:)), clockLeft: clock?.remaining[safe: index] ?? nil)
        }
        return nil
    }

    /// The fullmove number and side to move of a FEN.
    private static func turn(fen: String) -> (Int, Bool) {
        let fields = fen.split(separator: " ")
        return (fields.count > 5 ? Int(fields[5]) ?? 1 : 1, fields.count > 1 ? fields[1] == "w" : true)
    }

    /// "13. Bxa6 Qf6 14. Qe2", or "13… Bxc4 14. Qxc4" from Black's move, as the live lines read.
    static func notation(_ san: [String], fullmove: Int, whiteToMove: Bool, maxPlies: Int = 8) -> String {
        var number = fullmove, white = whiteToMove, parts: [String] = []
        for (index, move) in san.prefix(maxPlies).enumerated() {
            if white { parts.append("\(number). \(move)") }
            else { parts.append(index == 0 ? "\(number)\u{2026} \(move)" : move); number += 1 }
            white.toggle()
        }
        return parts.joined(separator: " ")
    }

    var currentPresentation: BoardPresentation {
        guard !snapshots.isEmpty else { return .empty }
        let index = min(boardPly, snapshots.count - 1)
        let lastMove = boardPly > 0 ? moves[boardPly - 1] : nil
        var presentation = BoardPresentation(pieces: snapshots[index],
                                             orientation: orientation,
                                             lastMove: lastMove,
                                             checkSquare: checkSquares[index])
        guard !isSummary, let lastMove else { return presentation }
        if isBookMove {
            presentation.badge = SquareBadge(square: lastMove.toSquare, text: "", color: Palette.book, symbol: "book.fill")
            return presentation
        }
        guard let move = currentMove else { return presentation }
        let mine = move.mover == playerColor
        if let severity = severity(of: move) {
            presentation.badge = SquareBadge(square: lastMove.toSquare, text: severity.marker, color: severity.color)
            if mine {
                // What to play instead, and how the opponent punishes what was played.
                presentation.suggestedMove = move.labels?.bestLineUCI.first.flatMap(Move.fromUCI)
                presentation.threatMove = move.lineUCI.first.flatMap(Move.fromUCI)
                presentation.targetRings = targets(of: move)
                let missed: Set<PatternTag> = [.missedCapture, .missedFork, .missedMate]
                presentation.ringColor = move.labels?.tags.first.map { missed.contains($0) } == true ? Palette.brand : Palette.blunder
            } else if let tag = move.labels?.tags.first, ![.missedCapture, .missedFork, .missedMate].contains(tag) {
                // The opponent's error is the player's chance: what it left open, in green.
                presentation.targetRings = targets(of: move)
                presentation.ringColor = Palette.best
            }
        } else if insights.moments[move.ply] == .punished {
            presentation.badge = SquareBadge(square: lastMove.toSquare, text: "", color: Palette.best, symbol: "checkmark")
        }
        return presentation
    }

    private func targets(of move: MoveAnalysis) -> [Int] {
        if let cached = targetCache[move.ply] { return cached }
        let squares = move.patternTargets
        targetCache[move.ply] = squares
        return squares
    }

    /// "12. Nf3" or "12… Nf6" for the move that produced the current position.
    var currentMoveLabel: String {
        guard boardPly > 0, boardPly <= sanMoves.count else { return "Start" }
        return moveLabel(boardPly - 1)
    }

    func moveLabel(_ index: Int) -> String {
        let number = index / 2 + 1
        return index % 2 == 0 ? "\(number). \(sanMoves[index])" : "\(number)\u{2026} \(sanMoves[index])"
    }

    var currentScore: EngineScore {
        if let move = currentMove { return move.scoreAfter }
        if boardPly > 0, let move = shownMoves.first(where: { $0.ply == boardPly - 1 }) { return move.scoreAfter }
        if let first = shownMoves.first { return first.scoreBefore }
        return .centipawns(0)
    }

    func step(_ delta: Int) {
        ply = min(max(0, ply + delta), lastPly)
    }

    /// The tracked player's errors in a deep review.
    var errorPlies: [Int] {
        (analysis?.moves ?? []).filter { isError($0) && $0.mover == playerColor }.map(\.ply)
    }

    /// The positions after the key moments: the player's errors and the chances they took.
    private var keyPlies: [Int] { insights.keyMoments.map { $0 + 1 } }

    /// Where Next key moment goes: the next one, then the summary, then back to the start.
    var nextKeyPly: Int {
        if isSummary { return 0 }
        return keyPlies.first { $0 > ply } ?? lastPly
    }

    var nextKeyTitle: String {
        if isSummary { return "Back to start" }
        return keyPlies.contains { $0 > ply } ? "Next key moment" : "Summary"
    }

    var previousKeyPly: Int? { keyPlies.last { $0 < ply } }

    // MARK: Graph and summary

    /// White's win percentage at each scored position.
    var graphPoints: [(ply: Int, win: Double)] {
        let moves = shownMoves.sorted { $0.ply < $1.ply }
        var points: [(Int, Double)] = []
        if let first = moves.first, first.ply == 0 { points.append((0, Scoring.winPercent(first.scoreBefore))) }
        points += moves.map { ($0.ply + 1, Scoring.winPercent($0.scoreAfter)) }
        return points
    }

    var graphMarkers: [GraphMarker] {
        guard showsLabels else { return [] }
        var markers: [GraphMarker] = []
        for move in shownMoves {
            let ply = move.ply + 1
            if insights.moments[move.ply] == .missedChance { markers.append(GraphMarker(ply: ply, kind: .missedChance)) }
            if let severity = severity(of: move) {
                markers.append(GraphMarker(ply: ply, kind: move.mover == playerColor ? .playerError(severity) : .opponentError(severity)))
            } else if insights.moments[move.ply] == .punished {
                markers.append(GraphMarker(ply: ply, kind: .punished))
            }
        }
        return markers
    }

    var graphPhases: [(phase: GamePhase, ply: Int)] {
        insights.phaseStarts.map { (phase: $0.key, ply: $0.value) }.sorted { $0.ply < $1.ply }
    }

    /// The player's time per move, for ticks under the graph: a fast error in its colour, a long
    /// think in amber.
    var graphTicks: [GraphTick] {
        guard let clock else { return [] }
        return clock.spent.indices.compactMap { index in
            guard (index % 2 == 0) == (playerColor == .white), let spent = clock.spent[index] else { return nil }
            let severity = shownMoves.first { $0.ply == index }.flatMap(severity(of:))
            let tint: Color
            if let severity, spent <= 5 { tint = severity.color }
            else if spent >= 60 { tint = Palette.brand }
            else { tint = Color.white.opacity(0.32) }
            return GraphTick(ply: index + 1, spent: spent, tint: tint)
        }
    }

    var lowTimePly: Int? { clock?.lowTimeStart(for: playerColor).map { $0 + 1 } }

    var summary: ReviewSummary? {
        guard hasDeepReview, let entry, let analysis, !moves.isEmpty else { return nil }
        let opponentColor = playerColor.opposite
        let result: String = {
            let loser: GameSide? = entry.outcome == .win ? entry.opponent : entry.outcome == .loss ? entry.player : nil
            let how = loser.map { ResultCodes.description(for: $0.resultCode) } ?? ResultCodes.description(for: entry.player.resultCode)
            return "\(entry.outcome.label) · \(how) · move \((moves.count + 1) / 2)"
        }()
        var facts: [ReviewSummary.Fact] = []
        if let exit = bookExitIndex {
            facts.append(.init(label: "Left book", value: moveLabel(exit) + (theoryMove.map { " · theory was \($0)" } ?? ""), ply: exit + 1))
        }
        if let worst = insights.biggestError, let move = analysis.moves[safe: worst], let severity = severity(of: move) {
            let best = move.labels?.bestMoveSAN.map { " · best was \($0)" } ?? ""
            facts.append(.init(label: "Biggest swing", value: moveLabel(worst) + severity.marker + best, ply: worst + 1))
        }
        let taken = insights.moments.filter { $0.value == .punished }.map(\.key).sorted()
        let missed = insights.moments.filter { $0.value == .missedChance }.map(\.key).sorted()
        if !taken.isEmpty || !missed.isEmpty {
            facts.append(.init(label: "Chances", value: "Took \(taken.count) of \(taken.count + missed.count)",
                               ply: (missed.first ?? taken.first).map { $0 + 1 }))
        }
        if let clock {
            let final = playerColor == .white ? clock.clocks(afterPlies: moves.count).white : clock.clocks(afterPlies: moves.count).black
            if let low = clock.lowTimeStart(for: playerColor) {
                facts.append(.init(label: "Clock", value: "Under \(GameClock.format(clock.lowTime)) from move \(low / 2 + 1)"
                                   + (final.map { " · \(GameClock.format($0)) left" } ?? ""), ply: low + 1))
            } else if let final {
                facts.append(.init(label: "Clock", value: "\(GameClock.format(final)) left at the end", ply: nil))
            }
        }
        let phases = GamePhase.allCases.compactMap { phase -> (phase: GamePhase, player: Double?, opponent: Double?)? in
            guard let accuracy = insights.phaseAccuracy[phase] else { return nil }
            return (phase, playerColor == .white ? accuracy.white : accuracy.black, playerColor == .white ? accuracy.black : accuracy.white)
        }
        return ReviewSummary(result: result,
                             player: .init(name: entry.player.username, accuracy: analysis.accuracy(for: playerColor),
                                           errors: insights.errorCounts[playerColor] ?? [:], isPlayer: true),
                             opponent: .init(name: entry.opponent.username, accuracy: analysis.accuracy(for: opponentColor),
                                             errors: insights.errorCounts[opponentColor] ?? [:], isPlayer: false),
                             phases: phases,
                             facts: facts)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - W09 Game review

/// Where the analysis happens. The board runs edge to edge under a thin evaluation line, the
/// engine's live lines sit right under it, and the game is stepped through with a small floating
/// control or a swipe across the board.
///
/// Opening a game starts its analysis, at the deepest level the app runs (`DeepReview`), unless
/// it already has one. There is no separate quick analysis to choose.
struct GameReviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openMistakes) private var openMistakes
    let gameKey: String
    let initialPly: Int?

    @State private var review = GameReviewModel()
    @State private var liveLines = LiveLinesModel()
    /// Cached rather than queried from the body: the body re-evaluates on every drag of the
    /// evaluation graph, and a database hit per frame is not acceptable there.
    @State private var isQueuedHere = false
    @State private var refusal: AppModel.ReviewRefusal?
    @Namespace private var chipSelection
    @Namespace private var playerRows
    /// The record in this opening, opened by a tap; it also opens by itself where the game
    /// leaves the book.
    @State private var isRecordOpen = false
    /// The player's errors already sent to the Mistakes backlog on this visit, by ply.
    @State private var collectedErrors: Set<Int> = []
    /// Errors that have landed in the tray, and a tick for its bounce as each one lands.
    @State private var trayCount = 0
    @State private var trayLandings = 0
    @State private var flights: [MistakeFlight] = []
    /// In the review's coordinate space, for the flights.
    @State private var boardFrame: CGRect = .zero
    @State private var trayFrame: CGRect = .zero

    private var stepAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.24) }

    var body: some View {
        Group {
            if review.entry == nil {
                EmptyState(symbol: "questionmark.square.dashed",
                           title: "That game is not stored",
                           message: "It may have been removed with a player profile.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if dynamicTypeSize.isAccessibilitySize {
                // Text this large cannot share one screen with a full-size board: scroll instead.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { reviewRows }
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            } else {
                // Everything on one screen: the board takes the height the rows leave, up to the
                // full width, so nothing ever sits under the controls.
                ReviewColumnLayout { reviewRows }
            }
        }
        .animation(.smooth(duration: 0.35), value: review.hasReview)
        .animation(.smooth(duration: 0.35), value: review.hasDeepReview)
        // Only the status's arrival and departure animate: its text changes with every
        // progress tick, and animating those would never let one state finish fading.
        .animation(.smooth(duration: 0.3), value: statusKind == nil)
        .coordinateSpace(name: Self.space)
        .overlay { MistakeFlightLayer(flights: flights) }
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !review.moves.isEmpty { controls }
        }
        #if DEBUG
        // `-autoplay`: steps through the game on its own, to watch the board animate.
        .task(id: review.moves.count) {
            guard ProcessInfo.processInfo.arguments.contains("-autoplay"), !review.moves.isEmpty else { return }
            while !Task.isCancelled, review.ply < review.moves.count {
                try? await Task.sleep(nanoseconds: 700_000_000)
                step(1)
            }
        }
        #endif
        // The review is a focused task: its own controls replace the tab bar.
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(review.entry?.opponent.username ?? "Game review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let entry = review.entry {
                    VStack(spacing: 0) {
                        Text(entry.opponent.username)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(entry.outcome.label) · \(entry.game.timeControlLabel) · \(Format.relative(entry.game.endTime))")
                            .font(.caption)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let start = review.exploreStart {
                    NavigationLink(value: Route.explore(start)) {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .accessibilityLabel("Explore from this position")
                    .accessibilityHint("Play moves of your own from here, for both sides or against the engine")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { review.orientation = review.orientation.opposite }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Flip board")
            }
        }
        .task(id: "\(gameKey)|\(model.dataVersion)|\(model.coordinator.counts.completed)|\(model.coordinator.counts.pending)") {
            review.load(app: model, gameKey: gameKey, initialPly: initialPly)
            isQueuedHere = ((try? model.queue.activeItem(gameKey: gameKey, policyID: DeepReview.identifier)) ?? nil) != nil
        }
        .sensoryFeedback(.selection, trigger: review.ply)
        .onChange(of: review.boardPly) { _, _ in refreshLines() }
        .onChange(of: review.ply) { _, _ in collectCurrentError() }
        .onChange(of: review.hasDeepReview) { _, _ in collectCurrentError() }
        .onChange(of: review.moves.count) { _, _ in refreshLines() }
        .onChange(of: model.coordinator.partialReviews[gameKey]?.count ?? 0, initial: true) { _, _ in
            // Kept once the review finishes, until the saved one is loaded in its place.
            if let moves = model.coordinator.partialReviews[gameKey] { review.partial = moves }
        }
        .onChange(of: isTooHotForLines) { _, _ in refreshLines() }
        .onChange(of: showsEngine) { _, _ in refreshLines() }
        .onAppear {
            if model.reveal?.gameKey == gameKey { model.reveal?.hasArrived = true }
        }
        .onDisappear { liveLines.clear() }
    }

    /// The review, top to bottom. Every row under the board keeps its height whatever the
    /// analysis is doing, so the board never changes size as results arrive.
    @ViewBuilder
    private var reviewRows: some View {
        if let entry = review.entry {
            openingLine
                .padding(.horizontal, Layout.contentInset)
            if showsEngine {
                EvaluationLine(score: barScore,
                               orientation: review.orientation,
                               isSettled: review.hasReview || review.partialScore != nil || !liveLines.lines.isEmpty)
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            } else {
                Color.clear.frame(height: 6)
            }
            playerRow(review.orientation.opposite, entry: entry)
                .padding(.leading, Layout.contentInset)
                .padding(.trailing, Layout.gutter)
                .padding(.bottom, 2)
            // Edge to edge: the board is the content. Past the last move it steps back for the
            // summary, which takes its place.
            ZStack {
                BoardView(presentation: boardPresentation, cornerRadius: 0)
                    .scaleEffect(review.isSummary ? 0.92 : 1)
                    .blur(radius: review.isSummary ? 7 : 0)
                    .opacity(review.isSummary ? 0.2 : 1)
                    .allowsHitTesting(!review.isSummary)
                    .accessibilityHidden(review.isSummary)
                if review.isSummary, let summary = review.summary {
                    SummaryCard(summary: summary) { go(to: $0) }
                        .transition(.opacity.combined(with: .offset(y: 16)))
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: review.isSummary)
            .simultaneousGesture(swipeToStep)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { boardFrame = $0 }
            .layoutValue(key: IsReviewBoard.self, value: true)
            playerRow(review.orientation, entry: entry)
                .padding(.leading, Layout.contentInset)
                .padding(.trailing, Layout.gutter)
                .padding(.top, 2)
            if showsEngine {
                linesPanel
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 4)
            }
            if showsEngine || statusKind != nil {
                timelineSlot
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 4)
            }
            if !review.moves.isEmpty {
                moveStrip
                    .padding(.horizontal, Layout.contentInset)
            }
        }
    }

    /// The evaluation graph once there is one, or the analysis's progress or problem until then.
    /// A game reviewed in bulk keeps its graph while the deeper analysis runs, with the progress
    /// as a badge and a thin line along its foot.
    private var timelineSlot: some View {
        ZStack(alignment: .leading) {
            if review.hasReview || review.isShowingPartial, statusKind.map(\.isInProgress) ?? true {
                evaluationGraph
                    .overlay(alignment: .bottom) {
                        if case .running(let percent)? = statusKind {
                            CoverageBar(fraction: Double(percent) / 100)
                                .frame(height: 2)
                                .animation(.easeOut(duration: 0.3), value: percent)
                        }
                    }
                    .overlay(alignment: .topTrailing) { inDepthBadge }
                    .transition(.opacity)
            } else if statusKind != nil {
                analysisStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: review.clock == nil ? 40 : EvaluationGraph.lineHeight + EvaluationGraph.tickHeight + 3)
    }

    @ViewBuilder
    private var inDepthBadge: some View {
        let text: String? = switch statusKind {
        case .running(let percent)?: "In depth \(percent)%"
        case .waiting(let reason)?: reason ?? "Starting in depth"
        default: nil
        }
        if let text {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.surfaceRaised))
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    /// The game's position, with an arrow for each live line once its search for this position
    /// has finished. Lines from the previous position are never drawn over the new one.
    private var boardPresentation: BoardPresentation {
        var presentation = review.currentPresentation
        // On the player's error the better move and the punishment are the arrows; live lines
        // would only crowd them.
        if !liveLines.isCalculating, !isTooHotForLines, presentation.threatMove == nil, !review.isSummary {
            presentation.lineArrows = liveLines.lines.compactMap(\.firstMove)
        }
        return presentation
    }

    // MARK: Mistakes backlog

    private static let space = "review"

    /// When the person lands on one of their own errors, it flies off the board into the tray:
    /// it is in the Mistakes backlog now, to be solved later. Once per error per visit.
    private func collectCurrentError() {
        guard review.hasDeepReview, let move = review.currentMove, move.mover == review.playerColor,
              let severity = review.severity(of: move), !collectedErrors.contains(move.ply),
              review.ply > 0, review.ply <= review.moves.count else { return }
        collectedErrors.insert(move.ply)
        AccessibilityNotification.Announcement("\(severity.label) added to your mistakes").post()

        guard !reduceMotion else {
            land()
            return
        }
        let ply = review.ply
        let square = review.moves[ply - 1].toSquare
        Task { @MainActor in
            // Let the verdict badge land on the board first; by then a review opened straight
            // onto this move has been laid out too.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard boardFrame != .zero, trayFrame != .zero else { return land() }
            let flight = MistakeFlight(text: "\(severity.marker) \(move.san)",
                                       color: severity.color,
                                       start: squareCentre(square),
                                       end: CGPoint(x: trayFrame.midX, y: trayFrame.midY))
            flights.append(flight)
            // A beat over the square, so it reads as this move's verdict leaving.
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeIn(duration: 0.5)) { setLaunched(flight.id) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            flights.removeAll { $0.id == flight.id }
            land()
        }
    }

    private func setLaunched(_ id: UUID) {
        guard let index = flights.firstIndex(where: { $0.id == id }) else { return }
        flights[index].isLaunched = true
    }

    private func land() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { trayCount += 1 }
        trayLandings += 1
    }

    private func squareCentre(_ square: Int) -> CGPoint {
        let size = min(boardFrame.width, boardFrame.height) / 8
        let column = review.orientation == .white ? Square.file(square) : 7 - Square.file(square)
        let row = review.orientation == .white ? 7 - Square.rank(square) : Square.rank(square)
        let originX = boardFrame.midX - size * 4
        return CGPoint(x: originX + (CGFloat(column) + 0.5) * size,
                       y: boardFrame.minY + (CGFloat(row) + 0.5) * size)
    }

    /// Where errors land: the Mistakes backlog, one tap away.
    private var mistakeTray: some View {
        Button {
            openMistakes()
        } label: {
            let total = review.errorPlies.count
            let isFull = total > 0 && trayCount >= total
            HStack(spacing: 4) {
                Image(systemName: isFull ? "tray.and.arrow.down.fill" : trayCount > 0 ? "tray.full.fill" : "tray")
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: "\(min(trayCount, total))/\(total)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(trayCount)))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(trayCount > 0 ? Palette.brand : Palette.inkTertiary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(isFull ? Palette.brandSoft : Color.white.opacity(0.08)))
            .animation(.smooth(duration: 0.3), value: isFull)
            // A long opening name truncates; the tray keeps its size.
            .fixedSize()
            .phaseAnimator([1.0, 1.3, 1.0], trigger: trayLandings) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in .spring(response: 0.18, dampingFraction: 0.6) }
            .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { trayFrame = $0 }
        .accessibilityLabel("Mistakes backlog")
        .accessibilityValue("\(trayCount) of \(review.errorPlies.count) errors from this game collected")
        .accessibilityHint("Opens the Mistakes tab")
    }

    // MARK: Stepping

    private func go(to ply: Int) {
        withAnimation(stepAnimation) { review.ply = min(max(0, ply), review.lastPly) }
    }

    private func step(_ delta: Int) { go(to: review.ply + delta) }

    /// Swipe left for the next move, right for the previous one. Mostly vertical drags are left
    /// to the scroll view.
    private var swipeToStep: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 40, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            }
    }

    // MARK: Analysis

    /// Whether the engine has anything to say here: a saved analysis, or one on its way. A game
    /// with neither is shown as it is, to go through without evaluations or engine lines.
    private var showsEngine: Bool {
        review.hasReview || review.isShowingPartial || isQueuedHere
            || model.coordinator.fraction(forGame: gameKey) != nil
    }

    /// Opening a game never starts its analysis (that is the rings' job in Games, and the rows on
    /// Analytics); this is only Try again after a failure.
    private func requestAnalysis() {
        refusal = model.requestReview(gameKey: gameKey, deep: true)
        if refusal == nil { isQueuedHere = true }
    }

    /// What the analysis of this game is doing, if anything worth a line.
    private enum StatusKind: Equatable {
        case running(Int)
        case paused
        case waiting(String?)
        case failed(String?)
        case unavailable(String)
        case noMoves
        case unreadable(String)
        case anotherGame

        /// Work under way that needs nothing from the viewer, so it can share the graph's slot.
        var isInProgress: Bool {
            switch self {
            case .running, .waiting: return true
            default: return false
            }
        }
    }

    private var statusKind: StatusKind? {
        if let parseError = review.parseError { return .unreadable(parseError) }
        if review.moves.isEmpty { return review.entry == nil ? nil : .noMoves }
        if let fraction = model.coordinator.fraction(forGame: gameKey) {
            return .running(Int((fraction * 100).rounded(.down)))
        }
        if review.hasDeepReview { return nil }
        if isQueuedHere {
            return model.coordinator.isPausedByUser ? .paused : .waiting(model.coordinator.primaryBlocker?.detail)
        }
        if let failure = review.deepFailure { return .failed(failure.errorMessage) }
        if case .engineUnavailable(let reason) = refusal { return .unavailable(reason) }
        if refusal == .anotherGameAnalysing { return .anotherGame }
        return nil
    }

    /// One quiet line, never a panel: the analysis is the screen's normal state, not an event.
    @ViewBuilder
    private var analysisStatus: some View {
        if let kind = statusKind {
            Group {
                switch kind {
                case .running(let percent):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(review.hasReview ? "Analysing in depth" : "Analysing")
                            Spacer()
                            Text("\(percent)%")
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(percent)))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        CoverageBar(fraction: Double(percent) / 100)
                            .frame(height: 3)
                            .animation(.easeOut(duration: 0.3), value: percent)
                    }
                case .paused:
                    statusLine("Analysis paused", tone: Palette.brass, actionTitle: "Resume") {
                        model.coordinator.resume()
                    }
                case .waiting(let reason):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(reason ?? "Starting the analysis")
                            .lineLimit(2)
                    }
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                case .failed(let message):
                    statusLine("Analysis failed\(message.map { ": \($0)" } ?? "")", tone: Palette.loss,
                               actionTitle: "Try again") { requestAnalysis() }
                case .unavailable(let reason):
                    statusLine("Analysis is unavailable. \(reason)", tone: Palette.loss)
                case .noMoves:
                    statusLine("No moves to analyse. The game still counts in your totals.", tone: Palette.inkSecondary)
                case .anotherGame:
                    statusLine("Another game is being analysed. Games are analysed one at a time.",
                               tone: Palette.inkSecondary)
                case .unreadable(let detail):
                    statusLine("This game's notation could not be fully read: \(detail)", tone: Palette.brass)
                }
            }
            .transaction { $0.animation = nil }
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
    }

    private func statusLine(_ text: String, tone: Color, actionTitle: String? = nil,
                            action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(tone)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.brand)
            }
        }
    }

    // MARK: Engine lines

    /// The line follows the saved review where there is one, so it always agrees with the move
    /// list; before a game is reviewed it follows the live lines instead.
    private var barScore: EngineScore {
        if review.hasReview { return review.currentScore }
        if let score = review.partialScore { return score }
        return liveLines.lines.first?.score ?? .centipawns(0)
    }

    /// Heat stops the engine for reviews as well as bulk work (§7), so the lines stop too.
    private var isTooHotForLines: Bool { model.conditions.blockers.contains(.thermal) }

    private func refreshLines() {
        guard showsEngine, !isTooHotForLines, let board = review.board(atPly: review.boardPly) else {
            liveLines.clear()
            return
        }
        liveLines.analyse(board)
    }

    @ViewBuilder
    private var linesPanel: some View {
        if !review.moves.isEmpty, liveLines.isAvailable {
            ZStack(alignment: .topLeading) {
                if let verdict = review.verdict, !isTooHotForLines || isErrorVerdict(verdict) {
                    VerdictPanel(verdict: verdict, liveLines: liveLines.lines, isCalculating: liveLines.isCalculating) {
                        openRepeatedKind()
                    }
                    .id(review.ply)
                    .transition(.opacity)
                } else {
                    EngineLinesPanel(lines: liveLines, isTooHot: isTooHotForLines)
                        .transition(.opacity)
                }
            }
            .frame(height: EngineLinesPanel.height, alignment: .top)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: review.verdict)
        }
    }

    private func isErrorVerdict(_ verdict: ReviewVerdict) -> Bool {
        if case .error = verdict { return true }
        return false
    }

    /// The repeat count opens Mistakes at every game's errors of this kind.
    private func openRepeatedKind() {
        guard let tag = review.currentMove?.labels?.tags.first else { return }
        openMistakes(kind: .pattern(tag))
    }

    // MARK: Sections

    /// The opening reached so far, above the evaluation line. A book move says so in front of
    /// the name; the move that leaves the book says what theory played instead. The player's
    /// record in the opening sits beside it, then the Mistakes tray.
    private var openingLine: some View {
        let opening = review.currentOpening
        let isBook = review.isBookMove
        let isExit = review.isBookExit
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                if isBook {
                    Label("Book", systemImage: "book.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.book)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
                if isExit {
                    Text(review.theoryMove.map { "Out of book · theory was \($0)" } ?? "Out of book")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.book)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 5)))
                } else if let opening {
                    if !opening.eco.isEmpty {
                        Text(opening.eco)
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    Text(opening.name)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .transition(.opacity.combined(with: .offset(y: -5)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(openingAccessibilityText(opening, isBook: isBook, isExit: isExit))
            Spacer(minLength: 0)
            if let record = review.openingRecord {
                OpeningRecordChip(record: record, isOpen: isRecordOpen || isExit) {
                    withAnimation(.smooth(duration: 0.4)) { isRecordOpen.toggle() }
                }
                .transition(.opacity)
            }
            if review.hasDeepReview {
                mistakeTray
                    .transition(.opacity)
            }
        }
        // The tray's height whether or not it shows, so the board never resizes for it.
        .frame(minHeight: 22)
        .animation(.smooth(duration: 0.25), value: isBook)
        .animation(.smooth(duration: 0.3), value: isExit)
        .animation(.smooth(duration: 0.25), value: opening)
    }

    private func openingAccessibilityText(_ opening: Opening?, isBook: Bool, isExit: Bool) -> String {
        var parts: [String] = []
        if isBook { parts.append("Book move") }
        if isExit { parts.append("Out of book" + (review.theoryMove.map { ", theory was \($0)" } ?? "")) }
        if let opening { parts.append("Opening: \(opening.name)\(opening.eco.isEmpty ? "" : ", \(opening.eco)")") }
        return parts.isEmpty ? "Opening not known" : parts.joined(separator: ". ")
    }

    /// One player beside the board. Rows follow their colour when the board flips: the two slide
    /// past each other.
    private func playerRow(_ color: PieceColor, entry: GameListEntry) -> some View {
        let isPlayer = color == review.playerColor
        let side = isPlayer ? entry.player : entry.opponent
        let ply = review.boardPly
        let balance = MaterialBalance(pieces: review.snapshots.indices.contains(ply) ? review.snapshots[ply] : [])
        let clocks = review.clock?.clocks(afterPlies: ply)
        let isOver = ply >= review.moves.count && !review.moves.isEmpty
        let result: String? = {
            guard isOver else { return nil }
            // The loser's way of losing, or the draw's reason; a clockless game keeps the old
            // place of the result at the top.
            if side.outcome == .loss || (side.outcome == .draw && color == .black) {
                return ResultCodes.description(for: side.resultCode)
            }
            return nil
        }()
        return ReviewPlayerRow(side: side,
                               color: color,
                               material: balance.ahead[color] ?? [],
                               lead: balance.lead(for: color),
                               accuracy: isPlayer ? accuracyForPlayer : nil,
                               clock: color == .white ? clocks?.white : clocks?.black,
                               isOnMove: !isOver && (ply % 2 == 0) == (color == .white),
                               lowTime: review.clock?.lowTime ?? 60,
                               result: result)
            .matchedGeometryEffect(id: color, in: playerRows)
            .id(color)
    }

    private var accuracyForPlayer: Double? {
        guard review.hasDeepReview else { return nil }
        return review.analysis?.accuracy(for: review.playerColor)
    }

    /// A slim line rather than a boxed chart: drag along it to move through the game. Phases
    /// are bands behind it, key moves are marked on it, and the player's time per move runs
    /// underneath when the game has a clock.
    private var evaluationGraph: some View {
        EvaluationGraph(points: review.graphPoints,
                        plyCount: max(1, review.moves.count),
                        markers: review.graphMarkers,
                        phases: review.showsLabels ? review.graphPhases : [],
                        showsPhaseLabels: review.isSummary,
                        ticks: review.graphTicks,
                        lowTimeFrom: review.lowTimePly,
                        selectedPly: review.boardPly) { ply in
            if ply != review.ply { go(to: ply) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evaluation graph, White's winning chances move by move")
        .accessibilityValue(graphSummary)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private var graphSummary: String {
        guard let last = review.shownMoves.last else { return "No evaluations." }
        let final = "Final evaluation \(last.scoreAfter.accessibleText)"
        guard review.hasDeepReview else { return final }
        let errors = (review.analysis?.moves ?? []).filter { review.isError($0) && $0.mover == review.playerColor }
        guard !errors.isEmpty else { return "\(final). No errors for the tracked player." }
        return final + ". " + errors.map { "\($0.moveNumberLabel) \($0.san), \(review.severity(of: $0)?.label ?? "")" }.joined(separator: "; ")
    }

    private var moveStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    moveChip(index: 0, label: "Start", marker: nil, caption: nil, isSelected: review.ply == 0)
                    ForEach(Array(review.sanMoves.enumerated()), id: \.offset) { index, san in
                        let analysed = review.shownMoves.first { $0.ply == index }
                        moveChip(index: index + 1,
                                 label: "\(index % 2 == 0 ? "\(index / 2 + 1)." : "")\(san)",
                                 marker: review.isBook(ply: index) ? .book : marker(for: analysed),
                                 caption: caption(forMove: index, analysed: analysed),
                                 isSelected: review.ply == index + 1)
                            .id(index + 1)
                    }
                    if review.lastPly > review.moves.count {
                        moveChip(index: review.lastPly, label: "Summary", marker: .summary, caption: nil,
                                 isSelected: review.isSummary)
                            .id(review.lastPly)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: review.ply) { _, value in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(max(1, value), anchor: .center) }
            }
            // Finished analysis adds markers that widen the chips: keep the current move centred.
            .onChange(of: "\(review.hasReview)|\(review.hasDeepReview)|\(review.isShowingPartial)") { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(max(1, review.ply), anchor: .center) }
            }
            .onAppear { proxy.scrollTo(max(1, review.ply), anchor: .center) }
        }
    }

    /// What a chip shows beside its move.
    private enum ChipMarker: Equatable {
        /// Which way the move moved the evaluation bar for the side that played it.
        case trend(EvalTrend)
        /// A deep review's label on one of the tracked player's moves; a missed chance adds a
        /// dashed ring.
        case severity(Severity, missedChance: Bool)
        /// The opponent's error, quieter: it is the player's chance, not their mistake.
        case opponentSeverity(Severity)
        /// The player took the opponent's error.
        case punished
        /// Known opening theory, for either side.
        case book
        case summary

        var accessibilityText: String {
            switch self {
            case .trend(let trend): return trend.label
            case .severity(let severity, let missed): return severity.label + (missed ? ", missed chance" : "")
            case .opponentSeverity(let severity): return "opponent's \(severity.label.lowercased())"
            case .punished: return "punished"
            case .book: return "book move"
            case .summary: return "game summary"
            }
        }
    }

    /// A deep review marks errors for both sides and the chances taken; a quicker review marks
    /// every move's trend.
    private func marker(for move: MoveAnalysis?) -> ChipMarker? {
        guard let move else { return nil }
        if review.showsLabels {
            if let severity = review.severity(of: move) {
                return move.mover == review.playerColor
                    ? .severity(severity, missedChance: review.insights.moments[move.ply] == .missedChance)
                    : .opponentSeverity(severity)
            }
            return review.insights.moments[move.ply] == .punished ? .punished : nil
        }
        return move.trend == .level ? nil : .trend(move.trend)
    }

    /// The move's time under its chip: a fast error in the mistake colour, a long think in
    /// amber, the player's moves once short of time in red.
    private func caption(forMove index: Int, analysed: MoveAnalysis?) -> (text: String, tint: Color)? {
        guard let clock = review.clock, let spent = clock.spent[index] else { return nil }
        let isPlayer = (index % 2 == 0) == (review.playerColor == .white)
        let tint: Color
        if isPlayer, spent <= 5, analysed.flatMap(review.severity(of:)) != nil { tint = Palette.mistake }
        else if spent >= 60 { tint = Palette.brand }
        else if isPlayer, let low = review.lowTimePly, index + 1 >= low { tint = Palette.blunder }
        else { tint = Palette.inkTertiary }
        return (GameClock.formatSpent(spent), tint)
    }

    private func moveChip(index: Int, label: String, marker: ChipMarker?, caption: (text: String, tint: Color)?,
                          isSelected: Bool) -> some View {
        Button {
            go(to: index)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.footnote.weight(isSelected ? .semibold : .regular))
                    switch marker {
                    case .trend(let trend):
                        Image(systemName: trend.symbol)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isSelected ? Palette.onBrand : trend.color)
                    case .severity(let severity, let missed):
                        Text(severity.marker)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isSelected ? Palette.onBrand : severity.color)
                        if missed {
                            Circle()
                                .strokeBorder(isSelected ? Palette.onBrand : Palette.brand,
                                              style: StrokeStyle(lineWidth: 1, dash: [1.6, 1.2]))
                                .frame(width: 6, height: 6)
                        }
                    case .opponentSeverity(let severity):
                        Text(severity.marker)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(isSelected ? Palette.onBrand : severity.color.opacity(0.55))
                    case .punished:
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(isSelected ? Palette.onBrand : Palette.best)
                    case .book:
                        Image(systemName: "book.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? Palette.onBrand : Palette.book)
                    case .summary:
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isSelected ? Palette.onBrand : Palette.brand)
                    case nil:
                        EmptyView()
                    }
                }
                .foregroundStyle(isSelected ? Palette.onBrand : Palette.ink)
                .padding(.horizontal, 11)
                .frame(minHeight: 32)
                .background {
                    if isSelected {
                        Capsule().fill(Palette.brand)
                            .matchedGeometryEffect(id: "selected-move", in: chipSelection)
                    } else {
                        Capsule().fill(Color.white.opacity(0.07))
                    }
                }
                if review.clock != nil {
                    Text(caption?.text ?? " ")
                        .font(.system(size: 9.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(caption?.tint ?? Palette.inkTertiary)
                        .frame(height: 11)
                }
            }
            .frame(minHeight: Layout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + (marker.map { ", \($0.accessibilityText)" } ?? "")
                            + (caption.map { ", \($0.text)" } ?? ""))
    }

    // MARK: Controls

    /// Its own row under the review, never over it: step back at the far left, forward at the far
    /// right, and the jump between key moments well clear of both in the middle, so a thumb aimed
    /// at one never lands on another.
    private var controls: some View {
        HStack(spacing: 12) {
            stepButton(by: -1, symbol: "chevron.left", label: "Previous move",
                       isDisabled: review.ply == 0)
            Spacer(minLength: 0)
            Group {
                if review.hasDeepReview {
                    keyMomentButton
                } else {
                    Text(review.currentMoveLabel)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            stepButton(by: 1, symbol: "chevron.right", label: "Next move",
                       isDisabled: review.ply >= review.lastPly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 6)
        .padding(.bottom, 4)
        // Opaque, for the scrolling layout at accessibility text sizes.
        .background(Palette.background)
    }

    private func stepButton(by delta: Int, symbol: String, label: String, isDisabled: Bool) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 72, height: Layout.minimumTarget)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .accessibilityLabel(label)
        .buttonRepeatBehavior(.enabled)
    }

    /// The player's errors and the chances they took, one after another, then the summary and
    /// back to the start. The previous one stays reachable from the menu.
    private var keyMomentButton: some View {
        Button {
            go(to: review.nextKeyPly)
        } label: {
            Text(review.nextKeyTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.onBrand)
                .padding(.horizontal, 16)
                .frame(height: Layout.minimumTarget)
                .background(Capsule().fill(Palette.brand))
                .contentTransition(.interpolate)
                .animation(.smooth(duration: 0.3), value: review.nextKeyTitle)
                .contentShape(Rectangle())
        }
        .contextMenu {
            Button("Previous key moment", systemImage: "chevron.backward.2") {
                if let ply = review.previousKeyPly { go(to: ply) }
            }
            .disabled(review.previousKeyPly == nil)
            Button("Summary", systemImage: "chart.bar") { go(to: review.lastPly) }
        }
        .accessibilityAction(named: "Previous key moment") {
            if let ply = review.previousKeyPly { go(to: ply) }
        }
    }
}

/// An error on its way from the board to the Mistakes tray.
struct MistakeFlight: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var color: Color
    var start: CGPoint
    var end: CGPoint
    var isLaunched = false
}

/// Draws the errors in flight over the review. Each pops up over its square, then shrinks into
/// the tray along a slight arc.
private struct MistakeFlightLayer: View {
    let flights: [MistakeFlight]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(flights) { flight in
                FlyingMistakeChip(flight: flight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FlyingMistakeChip: View {
    let flight: MistakeFlight
    @State private var hasAppeared = false

    var body: some View {
        Text(flight.text)
            .font(.footnote.weight(.heavy))
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(flight.color))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .scaleEffect(flight.isLaunched ? 0.35 : (hasAppeared ? 1 : 0.4))
            .opacity(flight.isLaunched ? 0.2 : (hasAppeared ? 1 : 0))
            .modifier(ArcPosition(progress: flight.isLaunched ? 1 : 0, start: flight.start, end: flight.end))
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { hasAppeared = true }
            }
    }
}

/// Moves a view from `start` to `end` along an arc that rises before it falls into the target.
private struct ArcPosition: ViewModifier, Animatable {
    var progress: Double
    let start: CGPoint
    let end: CGPoint

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        // A quadratic curve whose control point sits off to the side, above the midpoint.
        let control = CGPoint(x: (start.x + end.x) / 2 - 40, y: min(start.y, end.y) - 30)
        let x = (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * end.x
        let y = (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * end.y
        return content.position(x: x, y: y)
    }
}

/// Marks the board among the review's rows.
struct IsReviewBoard: LayoutValueKey {
    static let defaultValue = false
}

/// Stacks the review's rows top to bottom and gives the board the height the others leave, never
/// more than the full width, so the whole review fits on one screen. A board narrower than the
/// screen is centred; any height left over falls below the last row.
struct ReviewColumnLayout: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
        let heights = subviews.map { $0[IsReviewBoard.self] ? 0 : $0.sizeThatFits(rowProposal).height }
        let side = max(0, min(bounds.width, bounds.height - heights.reduce(0, +)))
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            if subview[IsReviewBoard.self] {
                subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top,
                              proposal: ProposedViewSize(width: side, height: side))
                y += side
            } else {
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height
            }
        }
    }
}
