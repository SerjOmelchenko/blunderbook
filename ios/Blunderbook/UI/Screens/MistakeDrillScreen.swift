//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// One mistake replayed as a puzzle: the moves that led to it play in, then the position before
/// it waits with the move that was played as a red arrow, and the board is open for a better
/// one. Two hints come before the answer. Once it is over, the game's line and the better one
/// can each be played out on the board.
@MainActor
@Observable
final class MistakeDrillModel {
    enum Phase: Equatable {
        /// The moves before the mistake are playing in.
        case leadIn
        case thinking
        case checking(san: String)
        /// `loss` is nil when there was no engine to measure the tried move.
        case wrong(san: String, loss: Double?, isGameMove: Bool)
        case solved(san: String, isEngineMove: Bool)
        case revealed
    }

    /// A line that can be played out once the puzzle is over.
    enum Line: Equatable {
        /// The move from the game and how it was punished.
        case game
        /// The engine's line.
        case best
    }

    /// Time allowed in the speed drill.
    static let speedLimit: TimeInterval = 10

    let occurrence: MistakeOccurrence
    private(set) var phase: Phase = .thinking
    private(set) var pieces: [Piece?]
    /// The tried move while it is on the board.
    private(set) var attempt: Move?
    private(set) var selected: Int?
    /// The opponent's move just before the mistake, or the lead-in move on the board.
    private(set) var leadInMove: Move?
    /// 0 none, 1 the piece is ringed, 2 the pattern is named. The next asks for the answer.
    private(set) var hintLevel = 0
    private(set) var wrongTries = 0
    /// The speed drill's end, while it runs.
    private(set) var deadline: Date?
    private(set) var timedOut = false
    /// The drill's first ending, which is what counts.
    private(set) var result: DrillResult?
    /// The line being played out on the board, and its last move.
    private(set) var shownLine: Line?
    private(set) var lineMove: Move?
    /// Called once, with the drill's result.
    var onResult: ((DrillResult) -> Void)?

    /// The position the mistake was played in.
    private let start: ChessBoard?
    private let judge = MoveJudge()
    /// Bumped on every attempt, so a late reset never undoes a newer one.
    private var attemptNumber = 0
    private var lineNumber = 0
    private var leadIn: DrillLeadIn?
    private var speedDrill = false

    init(occurrence: MistakeOccurrence) {
        self.occurrence = occurrence
        start = ChessBoard(fen: occurrence.fenBefore)
        pieces = start?.snapshot ?? BoardPresentation.empty.pieces
    }

    var isAvailable: Bool { start != nil }
    var mover: PieceColor { occurrence.color }
    var isFinished: Bool {
        switch phase {
        case .solved, .revealed: return true
        default: return false
        }
    }

    var bestMoveSAN: String? {
        if let san = occurrence.bestMoveSAN { return san }
        guard let start, let best = occurrence.bestMove, start.isLegalMove(best) else { return nil }
        return start.san(for: best)
    }

    private var targets: [Int] {
        guard let start, let selected, attempt == nil else { return [] }
        return start.legalMoves().filter { $0.fromSquare == selected }.map(\.toSquare)
    }

    var presentation: BoardPresentation {
        var presentation = BoardPresentation(pieces: pieces, orientation: mover)
        if phase == .leadIn {
            presentation.lastMove = leadInMove
            return presentation
        }
        if let shownLine {
            presentation.lastMove = lineMove
            presentation.isHypothetical = shownLine == .best
            return presentation
        }
        presentation.selectedSquare = selected
        presentation.targetSquares = targets
        if let attempt {
            presentation.lastMove = attempt
            switch phase {
            case .solved:
                presentation.badge = SquareBadge(square: attempt.toSquare, text: "", color: Palette.best, symbol: "checkmark")
            case .wrong:
                presentation.badge = SquareBadge(square: attempt.toSquare, text: "", color: Palette.blunder, symbol: "xmark")
            default:
                break
            }
        } else {
            presentation.lastMove = leadInMove
            presentation.mistakeMove = occurrence.move
            if phase == .revealed, let best = occurrence.bestMove {
                presentation.lineArrows = [best]
            }
            if hintLevel >= 1, !isFinished, let best = occurrence.bestMove {
                presentation.targetRings = [best.fromSquare]
                presentation.ringColor = Palette.brand
            }
        }
        return presentation
    }

    // MARK: Lead-in

    /// Plays the moves before the mistake in, unless `animated` is false, then starts the
    /// puzzle; with `speedDrill`, against the clock when the mistake was.
    func begin(leadIn: DrillLeadIn?, animated: Bool, speedDrill: Bool) async {
        self.leadIn = leadIn
        self.speedDrill = speedDrill
        guard animated, let leadIn, let board = ChessBoard(fen: leadIn.fen), let start else { return finishLeadIn() }
        phase = .leadIn
        pieces = board.snapshot
        leadInMove = nil
        try? await Task.sleep(for: .milliseconds(500))
        for move in leadIn.moves {
            guard phase == .leadIn, board.isLegalMove(move) else { break }
            board.makeMove(move)
            pieces = board.snapshot
            leadInMove = move
            try? await Task.sleep(for: .milliseconds(780))
        }
        guard phase == .leadIn else { return }
        if pieces != start.snapshot { pieces = start.snapshot }
        finishLeadIn()
    }

    /// Straight to the puzzle, from a tap during the lead-in.
    func skipLeadIn() {
        guard phase == .leadIn else { return }
        pieces = start?.snapshot ?? pieces
        finishLeadIn()
    }

    private func finishLeadIn() {
        leadInMove = leadIn?.moves.last
        phase = .thinking
        if speedDrill { startClock() }
    }

    // MARK: Speed drill

    var offersSpeedDrill: Bool { occurrence.isAgainstTheClock }

    func setSpeedDrill(_ on: Bool) {
        speedDrill = on
        if on, phase == .thinking || isWrong { startClock() } else if !on { deadline = nil }
    }

    private var isWrong: Bool {
        if case .wrong = phase { return true }
        return false
    }

    private func startClock() {
        guard offersSpeedDrill, !isFinished, deadline == nil, !timedOut else { return }
        let end = Date().addingTimeInterval(Self.speedLimit)
        deadline = end
        Task {
            try? await Task.sleep(for: .seconds(Self.speedLimit))
            guard deadline == end, !isFinished else { return }
            timedOut = true
            deadline = nil
        }
    }

    // MARK: Hints

    /// Rings the piece to move, then names the pattern, then shows the answer. Without an engine
    /// move there is no piece to ring, so the pattern comes first.
    func hint() {
        guard isAvailable, !isFinished, phase != .leadIn else { return }
        switch hintLevel {
        case 0: hintLevel = occurrence.bestMove == nil ? 2 : 1
        case 1: hintLevel = 2
        default: reveal()
        }
    }

    var hintTitle: String {
        switch hintLevel {
        case 0: return "Hint"
        case 1: return "Another hint"
        default: return "Show answer"
        }
    }

    /// The second hint: what to look for, from the mistake's kind.
    var hintText: String? {
        hintLevel >= 2 ? Self.hint(for: occurrence.kinds.first) : nil
    }

    static func hint(for kind: MistakeCategory?) -> String {
        switch kind {
        case .pattern(let tag)?:
            switch tag {
            case .undefendedPiece: return "The game move left a piece hanging. Keep everything defended."
            case .missedCapture: return "Something can be taken for free."
            case .allowedFork: return "The game move let a fork in. Stop it."
            case .missedFork: return "One move attacks two pieces at once."
            case .allowedAbsolutePin: return "The game move walked into a pin. Step out of it."
            case .allowedMate: return "The game move allowed mate. Look after the king."
            case .missedMate: return "There is a forced mate."
            }
        case .outcome(let consequence)?:
            switch consequence {
            case .losesMaterial: return "The game move lost material. Find one that keeps it."
            case .missesMaterialGain: return "Material can be won here."
            case .allowsMate: return "The game move allowed mate. Look after the king."
            case .missesForcedMate: return "There is a forced mate."
            case .lostWinningAdvantage: return "You were winning. Find the move that keeps it."
            case .evaluationLoss: return "No tactic here. Find the calm move that keeps the position."
            }
        default:
            return "Look for checks, captures and threats first."
        }
    }

    // MARK: Moves

    /// - Parameter onSolved: called once, when a tried move fixes the mistake.
    func tap(_ square: Int, onSolved: @escaping () -> Void) {
        if phase == .leadIn { return skipLeadIn() }
        guard let start, attempt == nil, !isFinished else { return }
        if case .checking = phase { return }
        let legal = start.legalMoves()

        if let selected {
            let candidates = legal.filter { $0.fromSquare == selected && $0.toSquare == square }
            if let move = preferred(candidates) {
                self.selected = nil
                play(move, from: start, onSolved: onSolved)
                return
            }
        }
        // Pick up a piece of the side to move, or put the current one down.
        let canMove = legal.contains { $0.fromSquare == square }
        selected = canMove && selected != square ? square : nil
    }

    /// A promotion takes the engine's choice of piece when it promotes on that square, a queen
    /// otherwise.
    private func preferred(_ candidates: [Move]) -> Move? {
        guard candidates.count > 1 else { return candidates.first }
        if let best = occurrence.bestMove, let match = candidates.first(where: { $0 == best }) { return match }
        return candidates.first { $0.promotion == .queen } ?? candidates.first
    }

    private func play(_ move: Move, from start: ChessBoard, onSolved: @escaping () -> Void) {
        let board = start.copy()
        let san = board.san(for: move)
        board.makeMove(move)
        attemptNumber += 1
        let number = attemptNumber
        attempt = move
        pieces = board.snapshot

        if move == occurrence.move {
            fail(san: san, loss: nil, isGameMove: true, attempt: number)
        } else if move == occurrence.bestMove {
            solve(san: san, isEngineMove: true, onSolved: onSolved)
        } else {
            phase = .checking(san: san)
            Task {
                let verdict = await judge.judge(board, mover: mover, before: occurrence.scoreBefore)
                guard number == attemptNumber else { return }
                switch verdict {
                case .good: solve(san: san, isEngineMove: false, onSolved: onSolved)
                case .bad(let loss): fail(san: san, loss: loss, isGameMove: false, attempt: number)
                case .unknown: fail(san: san, loss: nil, isGameMove: false, attempt: number)
                }
            }
        }
    }

    private func solve(san: String, isEngineMove: Bool, onSolved: () -> Void) {
        phase = .solved(san: san, isEngineMove: isEngineMove)
        deadline = nil
        onSolved()
        let clean = wrongTries == 0 && hintLevel == 0 && !timedOut
        finish(clean ? .clean : .helped)
    }

    private func finish(_ outcome: DrillResult) {
        guard result == nil else { return }
        result = outcome
        onResult?(outcome)
    }

    /// Leaves the tried move on the board long enough to see, then takes it back.
    private func fail(san: String, loss: Double?, isGameMove: Bool, attempt number: Int) {
        phase = .wrong(san: san, loss: loss, isGameMove: isGameMove)
        wrongTries += 1
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard number == attemptNumber, let start else { return }
            withAnimation(BoardView.moveAnimation) {
                attempt = nil
                pieces = start.snapshot
            }
        }
    }

    func reveal() {
        attemptNumber += 1
        lineNumber += 1
        selected = nil
        attempt = nil
        shownLine = nil
        deadline = nil
        pieces = start?.snapshot ?? pieces
        phase = .revealed
        finish(.revealed)
    }

    func retry() {
        attemptNumber += 1
        lineNumber += 1
        selected = nil
        attempt = nil
        shownLine = nil
        hintLevel = 0
        pieces = start?.snapshot ?? pieces
        phase = .thinking
    }

    // MARK: Lines

    /// Plays the game's move and its punishment, or the engine's line, from the puzzle's position.
    func play(_ line: Line) {
        guard isFinished, let start else { return }
        lineNumber += 1
        let number = lineNumber
        let moves: [Move] = switch line {
        case .game: [occurrence.move].compactMap { $0 } + occurrence.replyLineUCI.prefix(3).compactMap(Move.fromUCI)
        case .best: occurrence.bestLineUCI.prefix(4).compactMap(Move.fromUCI)
        }
        let board = start.copy()
        attempt = nil
        selected = nil
        shownLine = line
        lineMove = nil
        pieces = board.snapshot
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            for move in moves {
                guard number == lineNumber, board.isLegalMove(move) else { return }
                board.makeMove(move)
                pieces = board.snapshot
                lineMove = move
                try? await Task.sleep(for: .milliseconds(680))
            }
        }
    }
}

// MARK: - W14 Mistake drill

/// One mistake as a puzzle, or with several a training session: they follow one another and the
/// session ends on its result.
struct MistakeDrillScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("mistakes.speedDrill") private var speedDrill = false
    @State private var queue: [MistakeOccurrence]
    @State private var index = 0
    @State private var drill: MistakeDrillModel
    @State private var results: [DrillResult?]
    @State private var isShowingResult = false
    @State private var more: [MistakeOccurrence] = []
    @State private var shake = 0
    /// Set for a sample mistake in the Mistakes preview: solving it is reported here instead of
    /// saved, and there is no game behind it to open.
    private let onSampleSolved: ((MistakeOccurrence) -> Void)?
    /// Started from a session button rather than a card: the progress and result show even for one.
    private let isSession: Bool

    init(occurrence: MistakeOccurrence, onSampleSolved: ((MistakeOccurrence) -> Void)? = nil) {
        self.init(queue: [occurrence], isSession: false, onSampleSolved: onSampleSolved)
    }

    init(queue: [MistakeOccurrence], isSession: Bool = true, onSampleSolved: ((MistakeOccurrence) -> Void)? = nil) {
        let queue = queue.isEmpty ? [] : queue
        _queue = State(initialValue: queue)
        _drill = State(initialValue: MistakeDrillModel(occurrence: queue.first ?? MistakeOccurrence(
            gameKey: "", ply: 0, san: "", moveNumberLabel: "", severity: nil, phase: .opening, explanation: "",
            opponent: "", endTime: Date(), color: .white)))
        _results = State(initialValue: Array(repeating: nil, count: queue.count))
        self.onSampleSolved = onSampleSolved
        self.isSession = isSession
    }

    private var occurrence: MistakeOccurrence { drill.occurrence }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSession {
                DrillSessionProgress(results: results, current: isShowingResult ? nil : index)
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.bottom, 12)
            }
            if isShowingResult {
                SessionResultView(queue: queue, results: results, more: more.count,
                                  done: { dismiss() }, again: startMore)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 16)), removal: .opacity))
            } else {
                puzzle
                    .id(occurrence.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .clipped()
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isShowingResult { controls }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(isSession ? "Training" : "Find a better move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isShowingResult, drill.offersSpeedDrill {
                    Button {
                        speedDrill.toggle()
                        drill.setSpeedDrill(speedDrill)
                    } label: {
                        Image(systemName: speedDrill ? "stopwatch.fill" : "stopwatch")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .tint(speedDrill ? Palette.brand : nil)
                    .accessibilityLabel(speedDrill ? "Speed drill on" : "Speed drill off")
                    .accessibilityHint("Ten seconds for a mistake made against the clock")
                }
                if !isShowingResult, drill.isAvailable {
                    NavigationLink(value: Route.explore(exploreStart)) {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .accessibilityLabel("Explore from this position")
                    .accessibilityHint("Play moves of your own from here, for both sides or against the engine")
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: drill.phase)
        .animation(.smooth(duration: 0.3), value: drill.hintLevel)
        .sensoryFeedback(trigger: drill.phase) { _, phase in
            switch phase {
            case .solved: return .success
            case .wrong: return .error
            default: return nil
            }
        }
        .task(id: occurrence.id) { await begin() }
    }

    // MARK: Puzzle

    private var puzzle: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Layout.contentInset)
                .padding(.bottom, 10)
            SpeedBar(deadline: drill.deadline, timedOut: drill.timedOut, isOn: drill.offersSpeedDrill && speedDrill)
                .padding(.horizontal, Layout.contentInset)
                .padding(.bottom, 6)
            if drill.isAvailable {
                BoardView(presentation: drill.presentation, cornerRadius: 0) { square in
                    drill.tap(square) { markSolved() }
                }
                .modifier(Shake(amount: reduceMotion ? 0 : 5, shakes: CGFloat(shake)))
                .onChange(of: drill.wrongTries) { _, _ in withAnimation(.linear(duration: 0.32)) { shake += 1 } }
                feedback
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 12)
            } else {
                EmptyState(symbol: "questionmark.square.dashed",
                           title: "This position could not be read",
                           message: "Open the game to see the move in context.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(occurrence.moveNumberLabel) \(occurrence.san)")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                if let severity = occurrence.severity {
                    Badge(text: severity.label, tone: severity.color)
                }
                Spacer(minLength: 0)
                if occurrence.isSolved || isSolvedNow {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.best)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .accessibilityLabel("Solved")
                }
            }
            Text("You played the red arrow here against \(occurrence.opponent). Find a better move for \(drill.mover.name).")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if !occurrence.kinds.isEmpty { MistakeKindLabels(kinds: occurrence.kinds) }
                if let spent = occurrence.clock?.spent {
                    SpentLabel(spent: spent, isRushed: occurrence.has(.rushed), isShort: occurrence.has(.timeTrouble))
                }
                if !occurrence.repeats.isEmpty {
                    Text("\u{00D7}\(occurrence.repeats.count + 1) games")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.brass)
                }
            }
        }
    }

    /// The position the mistake was played in, to play on from freely.
    private var exploreStart: ExploreStart {
        ExploreStart(startFEN: occurrence.fenBefore, history: [], playerColor: occurrence.color,
                     orientation: occurrence.color,
                     origin: "Before \(occurrence.moveNumberLabel) \(occurrence.san)")
    }

    private var isSolvedNow: Bool {
        if case .solved = drill.phase { return true }
        return false
    }

    // MARK: Session

    private func begin() async {
        drill.onResult = { result in record(result) }
        let leadIn = onSampleSolved == nil ? (try? model.mistakeBook.leadIn(gameKey: occurrence.gameKey, ply: occurrence.ply)) ?? nil : nil
        await drill.begin(leadIn: leadIn, animated: !reduceMotion, speedDrill: speedDrill)
    }

    private func markSolved() {
        if let onSampleSolved { onSampleSolved(occurrence) }
    }

    /// Saves the drill's result, for this mistake and the same position in other games.
    private func record(_ result: DrillResult) {
        if index < results.count {
            withAnimation(.smooth(duration: 0.4)) { results[index] = result }
        }
        guard onSampleSolved == nil else { return }
        try? model.mistakeBook.record([occurrence.ref] + occurrence.repeats, result: result)
        model.touch()
        if isSession, index == queue.count - 1 { more = nextPick() }
    }

    private func next() {
        guard index + 1 < queue.count else {
            withAnimation(.smooth(duration: 0.45)) { isShowingResult = true }
            return
        }
        withAnimation(.smooth(duration: 0.45)) {
            index += 1
            drill = MistakeDrillModel(occurrence: queue[index])
        }
    }

    /// Another session's worth, leaving out what this one drilled.
    private func nextPick() -> [MistakeOccurrence] {
        guard let player = model.selectedPlayer,
              let occurrences = try? model.mistakeBook.occurrences(playerID: player.id, filters: model.filters,
                                                                   scope: model.scope, gameKey: model.mistakesGameKey)
        else { return [] }
        let done = Set(queue.map(\.id))
        return MistakeBook(occurrences: occurrences).trainingPick(count: 5 + queue.count).filter { !done.contains($0.id) }
            .prefix(5).map { $0 }
    }

    private func startMore() {
        guard !more.isEmpty else { return }
        withAnimation(.smooth(duration: 0.45)) {
            queue = more
            results = Array(repeating: nil, count: more.count)
            index = 0
            drill = MistakeDrillModel(occurrence: more[0])
            more = []
            isShowingResult = false
        }
    }

    // MARK: Feedback

    /// Under the board, always the same height so the board never moves.
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            if drill.isFinished {
                ComparePanel(occurrence: occurrence, bestSAN: drill.bestMoveSAN, shown: drill.shownLine) { drill.play($0) }
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else if let hint = drill.hintText {
                Label(hint, systemImage: "lightbulb")
                    .font(.footnote)
                    .foregroundStyle(Palette.brand)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else if drill.hintLevel == 1 {
                Label("The piece to move is ringed.", systemImage: "lightbulb")
                    .font(.footnote)
                    .foregroundStyle(Palette.brand)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 118, alignment: .topLeading)
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch drill.phase {
            case .leadIn:
                Image(systemName: "play.circle").foregroundStyle(Palette.inkSecondary)
                Text("How it came about. Tap the board to skip.")
                    .foregroundStyle(Palette.inkSecondary)
            case .thinking:
                YourMovePill(side: drill.mover.name)
                Text("Better than \(occurrence.san)?")
                    .foregroundStyle(Palette.inkSecondary)
            case .checking(let san):
                ProgressView().controlSize(.mini)
                Text("Checking \(san)…")
                    .foregroundStyle(Palette.inkSecondary)
            case .wrong(let san, let loss, let isGameMove):
                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.blunder)
                Text(wrongText(san: san, loss: loss, isGameMove: isGameMove))
                    .foregroundStyle(Palette.ink)
            case .solved(let san, let isEngineMove):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.best)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                Text(solvedText(san: san, isEngineMove: isEngineMove))
                    .foregroundStyle(Palette.ink)
            case .revealed:
                Image(systemName: "lightbulb.fill").foregroundStyle(Palette.best)
                Text(drill.bestMoveSAN.map { "The engine plays \($0), the green arrow." }
                     ?? "The review kept no engine move for this position.")
                    .foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 0)
            if drill.timedOut, !drill.isFinished {
                Text("Time")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.blunder)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.blunder.opacity(0.14)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.subheadline)
        .lineLimit(2)
        .accessibilityElement(children: .combine)
    }

    private func wrongText(san: String, loss: Double?, isGameMove: Bool) -> String {
        if isGameMove { return "\(san) is the move from the game. Try another." }
        guard let loss else { return "\(san) is not the engine's move. Try again." }
        let severity = Scoring.severity(forLoss: loss)?.label.lowercased() ?? "error"
        return "\(san) is also \(severity == "inaccuracy" ? "an" : "a") \(severity). Try again."
    }

    private func solvedText(san: String, isEngineMove: Bool) -> String {
        let prefix = drill.result == .clean ? "Solved at the first try." : "Solved."
        if isEngineMove { return "\(prefix) \(san) is the engine's move." }
        if let best = drill.bestMoveSAN { return "\(prefix) \(san) holds; the engine's choice was \(best)." }
        return "\(prefix) \(san) holds the position."
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            if onSampleSolved == nil {
                NavigationLink(value: Route.gameReview(gameKey: occurrence.gameKey, ply: occurrence.ply)) {
                    Text("Open game")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(height: Layout.minimumTarget)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
            }

            Spacer(minLength: 12)

            Group {
                switch drill.phase {
                case .leadIn:
                    secondaryButton("Skip") { drill.skipLeadIn() }
                case .solved:
                    primaryButton(continueTitle) { continueOn() }
                case .revealed:
                    secondaryButton("Try again") { drill.retry() }
                    primaryButton(continueTitle) { continueOn() }
                default:
                    secondaryButton(drill.hintTitle) { drill.hint() }
                        .contentTransition(.opacity)
                        .disabled(!drill.isAvailable)
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Palette.background)
    }

    private var continueTitle: String {
        guard isSession else { return "Done" }
        return index + 1 < queue.count ? "Next" : "Finish"
    }

    private func continueOn() {
        if isSession { next() } else { dismiss() }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(height: Layout.minimumTarget)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(Palette.ink)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.onBrand)
                .padding(.horizontal, 22)
                .frame(height: Layout.minimumTarget)
                .background(Capsule().fill(Palette.brand))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}

// MARK: - Drill parts

/// "Your move", with one slow glow as the puzzle opens.
private struct YourMovePill: View {
    let side: String
    @State private var glow = false

    var body: some View {
        Text("Your move")
            .font(.caption.weight(.bold))
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.brand))
            .shadow(color: Palette.brand.opacity(glow ? 0.55 : 0), radius: glow ? 8 : 0)
            .scaleEffect(glow ? 1.04 : 1)
            .task {
                withAnimation(.easeInOut(duration: 0.6)) { glow = true }
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeInOut(duration: 0.8)) { glow = false }
            }
            .accessibilityLabel("Your move, \(side)")
    }
}

/// The speed drill's ten seconds, running down above the board; red for the last three. Its
/// row keeps its height when off, so the board never moves.
private struct SpeedBar: View {
    let deadline: Date?
    let timedOut: Bool
    let isOn: Bool

    var body: some View {
        TimelineView(.animation(paused: deadline == nil)) { context in
            let left = deadline.map { max(0, $0.timeIntervalSince(context.date)) } ?? (timedOut ? 0 : MistakeDrillModel.speedLimit)
            let fraction = left / MistakeDrillModel.speedLimit
            GeometryReader { proxy in
                Capsule().fill(Color.white.opacity(isOn ? 0.07 : 0))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(left < 3 ? Palette.blunder : Palette.brand)
                            .frame(width: proxy.size.width * fraction)
                            .opacity(isOn ? 1 : 0)
                    }
            }
        }
        .frame(height: 3)
        .animation(.smooth(duration: 0.3), value: isOn)
        .accessibilityHidden(true)
    }
}

/// A small sideways shake, for a wrong try.
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 4), y: 0))
    }
}

/// Once the puzzle is over: the game's move against the better one, each with its evaluation and
/// played out on the board when tapped, over a bar of the player's chances in the line shown.
struct ComparePanel: View {
    let occurrence: MistakeOccurrence
    let bestSAN: String?
    let shown: MistakeDrillModel.Line?
    let play: (MistakeDrillModel.Line) -> Void

    private var gameScore: EngineScore { occurrence.scoreAfter.fromWhite(to: occurrence.color) }
    private var bestScore: EngineScore { occurrence.scoreBefore.fromWhite(to: occurrence.color) }

    var body: some View {
        VStack(spacing: 6) {
            row(.game, label: "In the game", san: occurrence.san, score: gameScore, tint: Palette.blunder)
            row(.best, label: "Best line", san: bestSAN ?? "\u{2014}", score: bestScore, tint: Palette.best)
            chances
        }
    }

    private func row(_ line: MistakeDrillModel.Line, label: String, san: String, score: EngineScore, tint: Color) -> some View {
        let isShown = shown == line
        return Button { play(line) } label: {
            HStack(spacing: 10) {
                Image(systemName: isShown ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 76, alignment: .leading)
                Text(san)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 6)
                Text(MistakeOccurrence.short(score))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isShown ? tint.opacity(0.12) : Color.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(label): \(san), \(score.accessibleText). Plays it on the board.")
    }

    /// The player's chances in the line on the board, the best line's until the game's is played.
    private var chances: some View {
        let score = shown == .game ? gameScore : bestScore
        let share = Scoring.winPercent(score) / 100
        return GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(shown == .game ? Palette.blunder : Palette.best)
                        .frame(width: proxy.size.width * share)
                }
        }
        .frame(height: 4)
        .animation(.smooth(duration: 0.7), value: shown)
        .accessibilityHidden(true)
    }
}

/// One segment per puzzle: filled with its result as it ends, the current one outlined.
struct DrillSessionProgress: View {
    let results: [DrillResult?]
    let current: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(results.indices, id: \.self) { index in
                Capsule()
                    .fill(results[index].map(SessionResultView.color) ?? Color.white.opacity(0.08))
                    .overlay(Capsule().strokeBorder(Palette.brand, lineWidth: current == index ? 1.5 : 0))
                    .frame(height: 5)
            }
        }
        .animation(.smooth(duration: 0.35), value: current)
        .accessibilityElement()
        .accessibilityLabel("Puzzle \(min((current ?? results.count - 1) + 1, results.count)) of \(results.count)")
    }
}

/// The session's end: how many at the first try, a mark per puzzle, what got fixed, and when
/// they come back.
struct SessionResultView: View {
    let queue: [MistakeOccurrence]
    let results: [DrillResult?]
    let more: Int
    let done: () -> Void
    let again: () -> Void

    @State private var shown = false
    @State private var counted = 0

    static func color(_ result: DrillResult) -> Color {
        switch result {
        case .clean: return Palette.best
        case .helped: return Palette.brand
        case .revealed: return Palette.blunder
        }
    }

    private var clean: Int { results.filter { $0 == .clean }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session complete").eyebrowStyle()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(counted)")
                        .font(.system(size: 56, weight: .bold).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText(value: Double(counted)))
                    Text("of \(results.count) at the first try")
                        .font(.title3)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            HStack(spacing: 10) {
                ForEach(results.indices, id: \.self) { index in
                    mark(results[index])
                        .scaleEffect(shown ? 1 : 0.3)
                        .opacity(shown ? 1 : 0)
                        .animation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.25 + Double(index) * 0.09), value: shown)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack {
                        Text(line).font(.subheadline).foregroundStyle(Palette.ink)
                        Spacer()
                    }
                    .frame(minHeight: 40)
                    .overlay(alignment: .bottom) { Hairline() }
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 6)
                    .animation(.smooth(duration: 0.45).delay(0.7 + Double(index) * 0.08), value: shown)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button("Done", action: done).buttonStyle(PrimaryButtonStyle())
                if more > 0 {
                    Button("Solve \(more) more", action: again).buttonStyle(SecondaryButtonStyle())
                }
            }
            .opacity(shown ? 1 : 0)
            .animation(.smooth(duration: 0.4).delay(0.9), value: shown)
        }
        .padding(.horizontal, Layout.contentInset)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .task {
            shown = true
            try? await Task.sleep(for: .milliseconds(250))
            for value in stride(from: 0, through: clean, by: 1) {
                withAnimation(.smooth(duration: 0.25)) { counted = value }
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private func mark(_ result: DrillResult?) -> some View {
        let tint = result.map(Self.color) ?? Palette.inkTertiary
        return Image(systemName: symbol(result))
            .font(.footnote.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(Circle().fill(tint.opacity(0.14)))
            .overlay(Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }

    private func symbol(_ result: DrillResult?) -> String {
        switch result {
        case .clean?: return "checkmark"
        case .helped?: return "lightbulb"
        case .revealed?: return "eye"
        case nil: return "minus"
        }
    }

    /// "2 hanging pieces fixed", then when they come back.
    private var lines: [String] {
        var byKind: [String: Int] = [:]
        var order: [String] = []
        for (occurrence, result) in zip(queue, results) where result == .clean || result == .helped {
            guard let kind = occurrence.kinds.first?.title else { continue }
            if byKind[kind] == nil { order.append(kind) }
            byKind[kind, default: 0] += 1
        }
        var lines = order.sorted { byKind[$0]! > byKind[$1]! }.prefix(2).map { "\(byKind[$0]!) \u{00D7} \($0) fixed" }
        let cleanCount = results.filter { $0 == .clean }.count
        let tomorrow = results.filter { $0 == .helped || $0 == .revealed }.count
        if tomorrow > 0 { lines.append("\(tomorrow) come\(tomorrow == 1 ? "s" : "") back tomorrow") }
        if cleanCount > 0 { lines.append("\(cleanCount) come\(cleanCount == 1 ? "s" : "") back in 3 days or more") }
        return lines
    }
}
