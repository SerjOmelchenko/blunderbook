//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI
import Charts

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
    private(set) var olderPolicyAnalyses: [AnalysisHeader] = []
    private var startFEN = ChessBoard.startFEN

    /// Number of moves played: 0 is the starting position, `moves.count` is the final position.
    var ply = 0
    var orientation: PieceColor = .white

    var game: GameRecord? { entry?.game }
    var playerColor: PieceColor { entry?.color ?? .white }
    var hasReview: Bool { analysis?.status == .complete && analysis?.isCurrentPolicy == true }

    func load(app: AppModel, gameKey: String, initialPly: Int?) {
        guard let player = app.selectedPlayer else { return }
        entry = (try? app.games.entry(playerID: player.id, gameKey: gameKey)) ?? nil
        analysis = (try? app.analyses.analysis(gameKey: gameKey)) ?? nil
        olderPolicyAnalyses = ((try? app.analyses.headers(gameKey: gameKey)) ?? [])
            .filter { !$0.isCurrentPolicy && $0.status == .complete }
        orientation = entry?.color ?? .white

        guard let game = entry?.game else { return }
        let parsed = PGNParser.parse(game.pgn)
        parseError = parsed.parseError
        moves = parsed.moves
        sanMoves = parsed.sanMoves
        startFEN = parsed.startFEN

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

        // A review reads from the start of the game, like a scoresheet. Mistakes stay one tap
        // away through Next mistake; a caller that wants a particular move passes it in.
        if let initialPly {
            ply = min(max(0, initialPly + 1), moves.count)
        } else {
            ply = 0
        }
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
        guard ply > 0 else { return nil }
        return analysis?.moves.first { $0.ply == ply - 1 }
    }

    var currentPresentation: BoardPresentation {
        guard !snapshots.isEmpty else { return .empty }
        let index = min(ply, snapshots.count - 1)
        var evidence: [Int] = []
        if let move = currentMove, move.isError, let best = move.bestLineUCI.first.flatMap(Move.fromUCI) {
            evidence = [best.toSquare]
        }
        return BoardPresentation(pieces: snapshots[index],
                                 orientation: orientation,
                                 lastMove: ply > 0 ? moves[ply - 1] : nil,
                                 suggestedMove: suggestedMove,
                                 checkSquare: checkSquares[index],
                                 evidenceSquares: evidence)
    }

    /// The engine's preferred move in the position *before* the selected one, drawn as an arrow.
    private var suggestedMove: Move? {
        guard let move = currentMove, move.isError else { return nil }
        return move.bestLineUCI.first.flatMap(Move.fromUCI)
    }

    var currentScore: EngineScore {
        if let move = currentMove { return move.scoreAfter }
        if let first = analysis?.moves.first { return first.scoreBefore }
        return .centipawns(0)
    }

    var errorPlies: [Int] {
        (analysis?.moves ?? []).filter { $0.isError && $0.mover == playerColor }.map(\.ply)
    }

    func step(_ delta: Int) {
        ply = min(max(0, ply + delta), moves.count)
    }

    func goToPreviousError() {
        let target = errorPlies.last { $0 + 1 < ply }
        if let target { ply = target + 1 }
    }

    func goToNextError() {
        let target = errorPlies.first { $0 + 1 > ply }
        if let target { ply = target + 1 }
    }

    var hasPreviousError: Bool { errorPlies.contains { $0 + 1 < ply } }
    var hasNextError: Bool { errorPlies.contains { $0 + 1 > ply } }
}

// MARK: - W09 Game review

struct GameReviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showPaywall) private var showPaywall
    let gameKey: String
    let initialPly: Int?

    @State private var review = GameReviewModel()
    @State private var liveLines = LiveLinesModel()
    /// Cached rather than queried from the body: the body re-evaluates on every drag of the
    /// evaluation graph, and a database hit per frame is not acceptable there.
    @State private var isQueuedHere = false
    @State private var refusal: AppModel.ReviewRefusal?

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let entry = review.entry {
                    playerLine(entry.opponent, isTop: true)
                        .padding(.horizontal, Layout.contentInset)
                        .padding(.vertical, 10)
                    // Edge to edge: the board is the content, and the controls float over it.
                    HStack(spacing: 0) {
                        EvaluationBar(score: barScore, orientation: review.orientation)
                        BoardView(presentation: review.currentPresentation, cornerRadius: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    playerLine(entry.player, isTop: false)
                        .padding(.horizontal, Layout.contentInset)
                        .padding(.vertical, 10)
                    linesPanel
                        .padding(.horizontal, Layout.contentInset)
                        .padding(.bottom, 10)
                    VStack(alignment: .leading, spacing: 18) {
                        analysisStateBlock
                        if review.hasReview {
                            evaluationGraph
                            moveStrip
                            annotationBlock
                        }
                        provenanceFooter
                            .id("review-end")
                    }
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 6)
                } else {
                    EmptyState(symbol: "questionmark.square.dashed",
                               title: "That game is not stored",
                               message: "It may have been removed with a player profile.")
                }
            }
            .padding(.bottom, 24)
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            if !review.moves.isEmpty { scrubber }
        }
        #if DEBUG
        // `-scroll-anchor bottom`: the review loads after it appears, so scroll once it has.
        .task(id: review.moves.count) {
            guard ProcessInfo.processInfo.arguments.contains("bottom"), !review.moves.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            scroller.scrollTo("review-end", anchor: .bottom)
        }
        #endif
        }
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
                Button {
                    review.orientation = review.orientation.opposite
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Flip board")
            }
        }
        .task(id: "\(gameKey)|\(model.dataVersion)|\(model.coordinator.counts.completed)|\(model.coordinator.counts.pending)") {
            review.load(app: model, gameKey: gameKey, initialPly: initialPly)
            isQueuedHere = ((try? model.queue.activeItem(gameKey: gameKey)) ?? nil) != nil
        }
        .onChange(of: review.ply) { _, _ in refreshLines() }
        .onChange(of: review.moves.count) { _, _ in refreshLines() }
        .onChange(of: isTooHotForLines) { _, _ in refreshLines() }
        .onDisappear { liveLines.clear() }
    }

    // MARK: Engine lines

    /// The bar follows the saved review where there is one, so it always agrees with the move's
    /// annotation; before a game is reviewed it follows the live lines instead.
    private var barScore: EngineScore {
        if review.hasReview { return review.currentScore }
        return liveLines.lines.first?.score ?? .centipawns(0)
    }

    /// Heat stops the engine for reviews as well as bulk work (§7), so the lines stop too.
    private var isTooHotForLines: Bool { model.conditions.blockers.contains(.thermal) }

    private func refreshLines() {
        guard !isTooHotForLines, let board = review.board(atPly: review.ply) else {
            liveLines.clear()
            return
        }
        liveLines.analyse(board)
    }

    @ViewBuilder
    private var linesPanel: some View {
        if !review.moves.isEmpty, liveLines.isAvailable {
            VStack(alignment: .leading, spacing: 0) {
                if isTooHotForLines {
                    Text("Engine lines pause while the phone is too warm.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(minHeight: 36)
                } else if liveLines.lines.isEmpty && !liveLines.isCalculating {
                    Text("No moves from here: the game is over.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(minHeight: 36)
                } else if liveLines.lines.isEmpty {
                    ForEach(0..<LiveLinesModel.lineCount, id: \.self) { _ in
                        engineLineRow(score: .centipawns(0), notation: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
                            .redacted(reason: .placeholder)
                    }
                } else {
                    ForEach(liveLines.lines) { line in
                        engineLineRow(score: line.score, notation: line.notation)
                    }
                }
            }
            .opacity(liveLines.isCalculating && !liveLines.lines.isEmpty ? 0.55 : 1)
            .animation(.easeOut(duration: 0.2), value: liveLines.isCalculating)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Engine lines")
        }
    }

    private func engineLineRow(score: EngineScore, notation: String) -> some View {
        let whiteAhead = score.sortValue >= 0
        return HStack(spacing: 10) {
            Text(verbatim: score.displayText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(whiteAhead ? Palette.pieceDark : Palette.ink)
                .frame(width: 54, height: 24)
                .background(Capsule().fill(whiteAhead ? Palette.pieceLight : Color.white.opacity(0.12)))
            Text(verbatim: notation)
                .font(.subheadline)
                .foregroundStyle(Palette.ink.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(score.accessibleText): \(notation)")
    }

    // MARK: Sections

    private func playerLine(_ side: GameSide, isTop: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isTop ? (review.orientation == .white ? Palette.pieceDark : Palette.pieceLight)
                            : (review.orientation == .white ? Palette.pieceLight : Palette.pieceDark))
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            Text(side.username)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let rating = side.rating {
                Text(verbatim: "\(rating)")
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if isTop, let entry = review.entry {
                Text(ResultCodes.description(for: entry.opponent.resultCode))
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
            } else if let accuracy = accuracyForPlayer {
                Text("Accuracy \(Format.accuracy(accuracy))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.brand)
                    .monospacedDigit()
            }
        }
    }

    private var accuracyForPlayer: Double? {
        guard review.hasReview else { return nil }
        return review.analysis?.accuracy(for: review.playerColor)
    }

    @ViewBuilder
    private var analysisStateBlock: some View {
        let entry = review.entry
        let runningFraction = model.coordinator.fraction(forGame: gameKey)

        if let parseError = review.parseError {
            InfoBanner(title: "This game's notation could not be fully read",
                       message: "\(parseError). The game still counts in your totals; no accuracy is invented for it.",
                       tone: .warning)
        }

        if review.moves.isEmpty {
            InfoBanner(title: "No moves to analyse",
                       message: "This completed game has no recorded moves. It still counts in your game totals.",
                       tone: .info)
        } else if let runningFraction {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading(title: "Analysing this game")
                    CoverageBar(fraction: runningFraction)
                    HStack {
                        Text("\(Int((runningFraction * 100).rounded(.down)))% analysed")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .monospacedDigit()
                        Spacer()
                        Button("Stop") { model.coordinator.pause() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.brand)
                    }
                    Text("The review is saved when the whole game is done. Stopping now means it starts over later; a game takes well under a minute.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
        } else if review.analysis?.status == .failed {
            InfoBanner(title: "Analysis failed",
                       message: review.analysis?.errorMessage,
                       tone: .error,
                       actionTitle: "Try again") { requestAnalysis() }
        } else if !review.hasReview {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    if let engineError = model.engineError {
                        InfoBanner(title: "Analysis is unavailable",
                                   message: "\(engineError) Saved reviews are unaffected and stay readable.",
                                   tone: .error)
                    } else if isQueuedHere {
                        InfoBanner(title: model.coordinator.isPausedByUser ? "Queued, but the queue is paused" : "Queued",
                                   message: model.coordinator.isPausedByUser
                                       ? "This game is next in line. Only Resume starts the queue again."
                                       : primaryBlockerMessage,
                                   tone: .warning,
                                   actionTitle: model.coordinator.isPausedByUser ? "Resume" : nil) {
                            model.coordinator.resume()
                        }
                    } else {
                        Text("This game has not been analysed yet.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)

                        Button("Analyse this game") { requestAnalysis() }
                            .buttonStyle(PrimaryButtonStyle())

                        if let refusal { refusalBanner(refusal) }
                    }
                }
            }
        } else if !review.olderPolicyAnalyses.isEmpty, review.analysis?.isCurrentPolicy == false {
            InfoBanner(title: "Reviewed under an older analysis policy",
                       message: "It stays readable exactly as it was saved, and is left out of current statistics.",
                       tone: .info,
                       actionTitle: "Reanalyse with the current policy") { requestAnalysis() }
        }

        if review.hasReview, review.errorPlies.isEmpty {
            InfoBanner(title: "No errors detected for \(review.entry?.player.username ?? "this player")",
                       message: "That is not the same as a perfect game: it means no move crossed the 5-point loss threshold.",
                       tone: .success)
        }
    }

    /// A slim line rather than a boxed chart: drag along it to move through the game.
    private var evaluationGraph: some View {
        let moves = review.analysis?.moves ?? []
        return Chart {
            RuleMark(y: .value("Level", 50))
                .foregroundStyle(Color.white.opacity(0.16))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(moves) { move in
                AreaMark(x: .value("Ply", move.ply + 1),
                         yStart: .value("Level", 50),
                         yEnd: .value("White", Scoring.winPercent(move.scoreAfter)))
                    .foregroundStyle(Color.white.opacity(0.08))
                    .interpolationMethod(.monotone)
            }
            ForEach(moves) { move in
                LineMark(x: .value("Ply", move.ply + 1),
                         y: .value("White", Scoring.winPercent(move.scoreAfter)))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            ForEach(moves.filter { $0.isError && $0.mover == review.playerColor }) { move in
                PointMark(x: .value("Ply", move.ply + 1),
                          y: .value("White", Scoring.winPercent(move.scoreAfter)))
                    .foregroundStyle(move.severity?.color ?? Palette.blunder)
                    .symbolSize(30)
            }
            if review.ply > 0 {
                RuleMark(x: .value("Selected", review.ply))
                    .foregroundStyle(Palette.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.zero) }
        .frame(height: 56)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let frame = proxy.plotFrame else { return }
                        let x = value.location.x - geometry[frame].origin.x
                        if let ply: Double = proxy.value(atX: x) {
                            review.ply = min(max(0, Int(ply.rounded())), review.moves.count)
                        }
                    })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evaluation graph, White's winning chances move by move")
        .accessibilityValue(graphSummary)
    }

    private var graphSummary: String {
        let errors = (review.analysis?.moves ?? []).filter { $0.isError && $0.mover == review.playerColor }
        guard !errors.isEmpty else { return "No errors for the tracked player." }
        return errors.map { "\($0.moveNumberLabel) \($0.san), \($0.severity?.label ?? "")" }.joined(separator: "; ")
    }

    private var moveStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    moveChip(index: 0, label: "Start", severity: nil, isSelected: review.ply == 0)
                    ForEach(Array(review.sanMoves.enumerated()), id: \.offset) { index, san in
                        let analysed = review.analysis?.moves.first { $0.ply == index }
                        moveChip(index: index + 1,
                                 label: "\(index % 2 == 0 ? "\(index / 2 + 1)." : "")\(san)",
                                 severity: analysed?.mover == review.playerColor ? analysed?.severity : nil,
                                 isSelected: review.ply == index + 1)
                            .id(index + 1)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: review.ply) { _, value in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(max(1, value), anchor: .center) }
            }
        }
    }

    private func moveChip(index: Int, label: String, severity: Severity?, isSelected: Bool) -> some View {
        Button {
            review.ply = index
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                if let severity {
                    Text(severity.marker)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? Palette.onBrand : severity.color)
                }
            }
            .foregroundStyle(isSelected ? Palette.onBrand : Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(Capsule().fill(isSelected ? Palette.brand : Color.white.opacity(0.08)))
            .frame(minHeight: Layout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + (severity.map { ", \($0.label)" } ?? ""))
    }

    /// What happened on the selected move, written on the ground rather than boxed.
    @ViewBuilder
    private var annotationBlock: some View {
        if let move = review.currentMove {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(move.moveNumberLabel) \(move.san)")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text(move.scoreAfter.displayText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        .monospacedDigit()
                }

                if let severity = move.severity {
                    Text("\(severity.label) · \(String(format: "%.1f", move.loss)) points lost · \(move.phase.label)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(severity.color)
                } else if move.isBest {
                    Text("Best move")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.best)
                }

                Text(move.explanation)
                    .font(.body)
                    .foregroundStyle(Palette.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                if !move.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(move.tags) { tag in
                            Badge(text: tag.label, tone: Palette.brand)
                        }
                    }
                }

            }
        }
    }

    /// Floating glass controls: step one move either way, or jump to the next mistake.
    private var scrubber: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 4) {
                Button { review.step(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.title2.weight(.semibold))
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                }
                .disabled(review.ply == 0)
                .accessibilityLabel("Previous move")

                if review.hasReview {
                    mistakeButton
                } else {
                    Text(review.ply == 0 ? "Start" : "Move \((review.ply + 1) / 2)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity)
                }

                Button { review.step(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.title2.weight(.semibold))
                        .frame(width: 72, height: 56)
                        .contentShape(Rectangle())
                }
                .disabled(review.ply >= review.moves.count)
                .accessibilityLabel("Next move")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .padding(4)
            .glassSurface(in: Capsule())
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 8)
    }

    /// Next mistake while there is one, then previous; both stay reachable from the menu.
    @ViewBuilder
    private var mistakeButton: some View {
        let forward = review.hasNextError
        let enabled = review.hasNextError || review.hasPreviousError
        Button {
            if forward { review.goToNextError() } else { review.goToPreviousError() }
        } label: {
            Text(enabled ? (forward ? "Next mistake" : "Previous mistake") : "No mistakes")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(enabled ? Palette.onBrand : Palette.inkSecondary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(enabled ? Palette.brand : Color.white.opacity(0.08)))
                .frame(maxWidth: .infinity, minHeight: Layout.minimumTarget)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .contextMenu {
            Button("Previous mistake", systemImage: "chevron.backward.2") { review.goToPreviousError() }
                .disabled(!review.hasPreviousError)
            Button("Next mistake", systemImage: "chevron.forward.2") { review.goToNextError() }
                .disabled(!review.hasNextError)
        }
        .accessibilityAction(named: "Previous mistake") { review.goToPreviousError() }
        .accessibilityAction(named: "Next mistake") { review.goToNextError() }
    }

    @ViewBuilder
    private var provenanceFooter: some View {
        if let analysis = review.analysis, analysis.status == .complete {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved \(Format.date(analysis.completedAt ?? analysis.createdAt)) · \(analysis.provenance.policyID)")
                Text("\(analysis.provenance.engineVersion) · \(analysis.provenance.evaluationVersion) · \(analysis.provenance.scoringVersion)")
            }
            .font(.caption2)
            .foregroundStyle(Palette.inkTertiary)
        }
    }

    private var primaryBlockerMessage: String? {
        model.coordinator.primaryBlocker?.detail
    }

    @ViewBuilder
    private func refusalBanner(_ refusal: AppModel.ReviewRefusal) -> some View {
        switch refusal {
        case .engineUnavailable(let reason):
            InfoBanner(title: "Analysis is unavailable", message: reason, tone: .error)
        case .noPlayer:
            InfoBanner(title: "Add a player first", message: nil, tone: .info)
        }
    }

    private func requestAnalysis() {
        refusal = model.requestReview(gameKey: gameKey)
        if refusal == nil { isQueuedHere = true }
    }
}
