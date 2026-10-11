//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
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
    /// The last deep review of this game, when it failed.
    private(set) var deepFailure: AnalysisHeader?
    /// Which opening each position had reached, and which moves were book.
    private(set) var openingTrace = OpeningTrace.empty
    private var startFEN = ChessBoard.startFEN
    /// The game on screen, so a reload after its analysis finishes keeps the person's place.
    private var loadedKey: String?

    /// Number of moves played: 0 is the starting position, `moves.count` is the final position.
    var ply = 0
    var orientation: PieceColor = .white

    var game: GameRecord? { entry?.game }
    var playerColor: PieceColor { entry?.color ?? .white }
    var hasReview: Bool { analysis?.status == .complete }
    var hasDeepReview: Bool { hasReview && analysis?.isDeep == true }

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
        guard !isReload || snapshots.isEmpty else { return }
        orientation = entry?.color ?? .white
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
        openingTrace = OpeningBook.shared.trace(startFEN: parsed.startFEN, moves: parsed.moves)

        // A review reads from the start of the game, like a scoresheet. Mistakes stay one tap
        // away through Next mistake; a caller that wants a particular move passes it in.
        if let initialPly {
            ply = min(max(0, initialPly + 1), moves.count)
        } else {
            ply = 0
        }
    }

    /// Where Explore starts from the position on screen: the real game up to `ply`, with its
    /// history, so repetitions still count in the new line.
    var exploreStart: ExploreStart? {
        guard entry != nil, ChessBoard(fen: startFEN) != nil else { return nil }
        return ExploreStart(startFEN: startFEN,
                            history: Array(moves.prefix(ply)),
                            playerColor: playerColor,
                            orientation: orientation,
                            origin: ply == 0 ? "From the starting position" : "After \(currentMoveLabel)")
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

    /// Whether the move at `ply` (0 is White's first move) is shown as a book move: known theory
    /// that the review did not find to be a blunder.
    func isBook(ply: Int) -> Bool {
        guard openingTrace.isBook(ply: ply) else { return false }
        return analysis?.moves.first { $0.ply == ply }?.severity != .blunder
    }

    /// Whether the move that produced the current position was a book move.
    var isBookMove: Bool { ply > 0 && isBook(ply: ply - 1) }

    /// The opening as of the current position. The starting position shows the opening the game
    /// went on to reach; a game the book does not know falls back to Chess.com's name for it.
    var currentOpening: Opening? {
        if let opening = ply == 0 ? openingTrace.opening : openingTrace.opening(afterPlies: ply) {
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

    var currentPresentation: BoardPresentation {
        guard !snapshots.isEmpty else { return .empty }
        let index = min(ply, snapshots.count - 1)
        var evidence: [Int] = []
        if let best = suggestedMove { evidence = [best.toSquare] }
        var badge: SquareBadge?
        if isBookMove {
            badge = SquareBadge(square: moves[ply - 1].toSquare, text: "", color: Palette.book, symbol: "book.fill")
        } else if let move = currentMove, let severity = severity(of: move), ply > 0 {
            badge = SquareBadge(square: moves[ply - 1].toSquare, text: severity.marker, color: severity.color)
        }
        return BoardPresentation(pieces: snapshots[index],
                                 orientation: orientation,
                                 lastMove: ply > 0 ? moves[ply - 1] : nil,
                                 suggestedMove: suggestedMove,
                                 checkSquare: checkSquares[index],
                                 evidenceSquares: evidence,
                                 badge: badge)
    }

    /// "12. Nf3" or "12… Nf6" for the move that produced the current position.
    var currentMoveLabel: String {
        guard ply > 0, ply <= sanMoves.count else { return "Start" }
        let index = ply - 1
        let number = index / 2 + 1
        return index % 2 == 0 ? "\(number). \(sanMoves[index])" : "\(number)\u{2026} \(sanMoves[index])"
    }

    /// In a deep review, the engine's preferred move in the position *before* a mistake, drawn as
    /// an arrow.
    private var suggestedMove: Move? {
        guard let move = currentMove, isError(move) else { return nil }
        return move.labels?.bestLineUCI.first.flatMap(Move.fromUCI)
    }

    var currentScore: EngineScore {
        if let move = currentMove { return move.scoreAfter }
        if let first = analysis?.moves.first { return first.scoreBefore }
        return .centipawns(0)
    }

    func step(_ delta: Int) {
        ply = min(max(0, ply + delta), moves.count)
    }

    /// The tracked player's errors in a deep review.
    var errorPlies: [Int] {
        (analysis?.moves ?? []).filter { isError($0) && $0.mover == playerColor }.map(\.ply)
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
    /// Set once this screen has asked for the analysis, so it never asks twice.
    @State private var hasRequestedAnalysis = false
    @State private var refusal: AppModel.ReviewRefusal?
    @Namespace private var chipSelection
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
                    withAnimation(.smooth(duration: 0.3)) { review.orientation = review.orientation.opposite }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Flip board")
            }
        }
        .task(id: "\(gameKey)|\(model.dataVersion)|\(model.coordinator.counts.completed)|\(model.coordinator.counts.pending)") {
            review.load(app: model, gameKey: gameKey, initialPly: initialPly)
            isQueuedHere = ((try? model.queue.activeItem(gameKey: gameKey, policyID: DeepReview.identifier)) ?? nil) != nil
            startAnalysisIfNeeded()
        }
        .sensoryFeedback(.selection, trigger: review.ply)
        .onChange(of: review.ply) { _, _ in refreshLines(); collectCurrentError() }
        .onChange(of: review.hasDeepReview) { _, _ in collectCurrentError() }
        .onChange(of: review.moves.count) { _, _ in refreshLines() }
        .onChange(of: isTooHotForLines) { _, _ in refreshLines() }
        .onDisappear { liveLines.clear() }
    }

    /// The review, top to bottom. Every row under the board keeps its height whatever the
    /// analysis is doing, so the board never changes size as results arrive.
    @ViewBuilder
    private var reviewRows: some View {
        if let entry = review.entry {
            openingLine
                .padding(.horizontal, Layout.contentInset)
            EvaluationLine(score: barScore,
                           orientation: review.orientation,
                           isSettled: review.hasReview || !liveLines.lines.isEmpty)
                .padding(.horizontal, Layout.contentInset)
                .padding(.top, 2)
                .padding(.bottom, 6)
            playerLine(entry.opponent, isTop: true)
                .padding(.horizontal, Layout.contentInset)
                .padding(.bottom, 4)
            // Edge to edge: the board is the content.
            BoardView(presentation: boardPresentation, cornerRadius: 0)
                .simultaneousGesture(swipeToStep)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { boardFrame = $0 }
                .layoutValue(key: IsReviewBoard.self, value: true)
            playerLine(entry.player, isTop: false)
                .padding(.horizontal, Layout.contentInset)
                .padding(.top, 4)
            linesPanel
                .padding(.horizontal, Layout.contentInset)
                .padding(.top, 4)
            timelineSlot
                .padding(.horizontal, Layout.contentInset)
                .padding(.top, 4)
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
            if review.hasReview, statusKind.map(\.isInProgress) ?? true {
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
        .frame(height: 40)
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
        if !liveLines.isCalculating, !isTooHotForLines {
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
            HStack(spacing: 4) {
                Image(systemName: trayCount > 0 ? "tray.full.fill" : "tray")
                Text("\(trayCount)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(trayCount)))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(trayCount > 0 ? Palette.brand : Palette.inkTertiary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.08)))
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
        .accessibilityValue("\(trayCount) from this game")
        .accessibilityHint("Opens the Mistakes tab")
    }

    // MARK: Stepping

    private func go(to ply: Int) {
        withAnimation(stepAnimation) { review.ply = min(max(0, ply), review.moves.count) }
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

    /// Asks for this game's analysis the first time it is opened without one. A game analysed
    /// in bulk gets the deeper analysis now; one whose analysis failed waits for Try again.
    private func startAnalysisIfNeeded() {
        guard !hasRequestedAnalysis, review.entry != nil, !review.moves.isEmpty, review.parseError == nil,
              !review.hasDeepReview, review.deepFailure == nil, !isQueuedHere, model.engineError == nil else { return }
        requestAnalysis()
    }

    private func requestAnalysis() {
        hasRequestedAnalysis = true
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
        if !review.hasReview, let engineError = model.engineError { return .unavailable(engineError) }
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
            EngineLinesPanel(lines: liveLines, isTooHot: isTooHotForLines)
        }
    }

    // MARK: Sections

    /// The opening reached so far, above the evaluation line. A book move says so in front of
    /// the name; the name keeps the last one reached once the game leaves the book.
    private var openingLine: some View {
        let opening = review.currentOpening
        let isBook = review.isBookMove
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                if isBook {
                    Label("Book", systemImage: "book.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.book)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
                if let opening {
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
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(openingAccessibilityText(opening, isBook: isBook))
            Spacer(minLength: 0)
            if review.hasDeepReview {
                mistakeTray
                    .transition(.opacity)
            }
        }
        // The tray's height whether or not it shows, so the board never resizes for it.
        .frame(minHeight: 22)
        .animation(.smooth(duration: 0.25), value: isBook)
        .animation(.smooth(duration: 0.25), value: opening)
    }

    private func openingAccessibilityText(_ opening: Opening?, isBook: Bool) -> String {
        var parts: [String] = []
        if isBook { parts.append("Book move") }
        if let opening { parts.append("Opening: \(opening.name)\(opening.eco.isEmpty ? "" : ", \(opening.eco)")") }
        return parts.isEmpty ? "Opening not known" : parts.joined(separator: ". ")
    }

    private func playerLine(_ side: GameSide, isTop: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isTop ? (review.orientation == .white ? Palette.pieceDark : Palette.pieceLight)
                            : (review.orientation == .white ? Palette.pieceLight : Palette.pieceDark))
                .frame(width: 9, height: 9)
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
            } else if !isTop, let accuracy = accuracyForPlayer {
                HStack(spacing: 6) {
                    AccuracyRing(value: accuracy, style: .inline)
                    Text("Accuracy \(Format.accuracy(accuracy))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.brand)
                        .monospacedDigit()
                }
                .transition(.opacity)
            }
        }
        .frame(minHeight: 22)
    }

    private var accuracyForPlayer: Double? {
        guard review.hasDeepReview else { return nil }
        return review.analysis?.accuracy(for: review.playerColor)
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
            ForEach(moves.filter { review.isError($0) && $0.mover == review.playerColor }) { move in
                PointMark(x: .value("Ply", move.ply + 1),
                          y: .value("White", Scoring.winPercent(move.scoreAfter)))
                    .foregroundStyle(review.severity(of: move)?.color ?? Palette.blunder)
                    .symbolSize(30)
            }
            if review.ply > 0 {
                RuleMark(x: .value("Selected", review.ply))
                    .foregroundStyle(Palette.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: 0...max(1, review.moves.count))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.zero) }
        .frame(height: 40)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard let frame = proxy.plotFrame else { return }
                        let x = value.location.x - geometry[frame].origin.x
                        if let ply: Double = proxy.value(atX: x) {
                            go(to: Int(ply.rounded()))
                        }
                    })
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evaluation graph, White's winning chances move by move")
        .accessibilityValue(graphSummary)
    }

    private var graphSummary: String {
        guard let last = review.analysis?.moves.last else { return "No evaluations." }
        let final = "Final evaluation \(last.scoreAfter.accessibleText)"
        guard review.hasDeepReview else { return final }
        let errors = (review.analysis?.moves ?? []).filter { review.isError($0) && $0.mover == review.playerColor }
        guard !errors.isEmpty else { return "\(final). No errors for the tracked player." }
        return final + ". " + errors.map { "\($0.moveNumberLabel) \($0.san), \(review.severity(of: $0)?.label ?? "")" }.joined(separator: "; ")
    }

    private var moveStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    moveChip(index: 0, label: "Start", marker: nil, isSelected: review.ply == 0)
                    ForEach(Array(review.sanMoves.enumerated()), id: \.offset) { index, san in
                        let analysed = review.analysis?.moves.first { $0.ply == index }
                        moveChip(index: index + 1,
                                 label: "\(index % 2 == 0 ? "\(index / 2 + 1)." : "")\(san)",
                                 marker: review.isBook(ply: index) ? .book : marker(for: analysed),
                                 isSelected: review.ply == index + 1)
                            .id(index + 1)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: review.ply) { _, value in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(max(1, value), anchor: .center) }
            }
            // Finished analysis adds markers that widen the chips: keep the current move centred.
            .onChange(of: "\(review.hasReview)|\(review.hasDeepReview)") { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(max(1, review.ply), anchor: .center) }
            }
            .onAppear { proxy.scrollTo(max(1, review.ply), anchor: .center) }
        }
    }

    /// What a chip shows beside its move.
    private enum ChipMarker: Equatable {
        /// Which way the move moved the evaluation bar for the side that played it.
        case trend(EvalTrend)
        /// A deep review's label on one of the tracked player's moves.
        case severity(Severity)
        /// Known opening theory, for either side.
        case book

        var accessibilityText: String {
            switch self {
            case .trend(let trend): return trend.label
            case .severity(let severity): return severity.label
            case .book: return "book move"
            }
        }
    }

    /// A deep review marks the tracked player's errors; a quicker review marks every move's trend.
    private func marker(for move: MoveAnalysis?) -> ChipMarker? {
        guard let move else { return nil }
        if review.hasDeepReview {
            guard move.mover == review.playerColor, let severity = review.severity(of: move) else { return nil }
            return .severity(severity)
        }
        return move.trend == .level ? nil : .trend(move.trend)
    }

    private func moveChip(index: Int, label: String, marker: ChipMarker?, isSelected: Bool) -> some View {
        Button {
            go(to: index)
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
                switch marker {
                case .trend(let trend):
                    Image(systemName: trend.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? Palette.onBrand : trend.color)
                case .severity(let severity):
                    Text(severity.marker)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? Palette.onBrand : severity.color)
                case .book:
                    Image(systemName: "book.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? Palette.onBrand : Palette.book)
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
            .frame(minHeight: Layout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + (marker.map { ", \($0.accessibilityText)" } ?? ""))
    }

    // MARK: Controls

    /// Its own row under the review, never over it: step back at the far left, forward at the far
    /// right, and the jump between mistakes well clear of both in the middle, so a thumb aimed
    /// at one never lands on another.
    private var controls: some View {
        HStack(spacing: 12) {
            stepButton(by: -1, symbol: "chevron.left", label: "Previous move",
                       isDisabled: review.ply == 0)
            Spacer(minLength: 0)
            Group {
                if review.hasDeepReview {
                    mistakeButton
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
                       isDisabled: review.ply >= review.moves.count)
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

    /// Next mistake while there is one, then previous; both stay reachable from the menu.
    @ViewBuilder
    private var mistakeButton: some View {
        let forward = review.hasNextError
        let enabled = review.hasNextError || review.hasPreviousError
        let title = enabled ? (forward ? "Next mistake" : "Previous mistake")
            : (review.errorPlies.isEmpty ? "No mistakes" : "The only mistake")
        Button {
            withAnimation(stepAnimation) {
                if forward { review.goToNextError() } else { review.goToPreviousError() }
            }
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(enabled ? Palette.onBrand : Palette.inkSecondary)
                .padding(.horizontal, 16)
                .frame(height: Layout.minimumTarget)
                .background(Capsule().fill(enabled ? Palette.brand : Color.white.opacity(0.08)))
                .contentTransition(.interpolate)
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
