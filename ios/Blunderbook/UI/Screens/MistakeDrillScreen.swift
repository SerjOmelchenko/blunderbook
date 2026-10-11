//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// One mistake replayed as a puzzle: the position before it, the move that was played as a red
/// arrow, and the board open for a better one.
@MainActor
@Observable
final class MistakeDrillModel {
    enum Phase: Equatable {
        case thinking
        case checking(san: String)
        /// `loss` is nil when there was no engine to measure the tried move.
        case wrong(san: String, loss: Double?, isGameMove: Bool)
        case solved(san: String, isEngineMove: Bool)
        case revealed
    }

    let occurrence: MistakeOccurrence
    private(set) var phase: Phase = .thinking
    private(set) var pieces: [Piece?]
    /// The tried move while it is on the board.
    private(set) var attempt: Move?
    private(set) var selected: Int?
    /// The position the mistake was played in.
    private let start: ChessBoard?
    private let judge = MoveJudge()
    /// Bumped on every attempt, so a late reset never undoes a newer one.
    private var attemptNumber = 0

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
            presentation.mistakeMove = occurrence.move
            if phase == .revealed, let best = occurrence.bestMove {
                presentation.lineArrows = [best]
            }
        }
        return presentation
    }

    // MARK: Moves

    /// - Parameter onSolved: called once, when a tried move fixes the mistake.
    func tap(_ square: Int, onSolved: @escaping () -> Void) {
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
        onSolved()
    }

    /// Leaves the tried move on the board long enough to see, then takes it back.
    private func fail(san: String, loss: Double?, isGameMove: Bool, attempt number: Int) {
        phase = .wrong(san: san, loss: loss, isGameMove: isGameMove)
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
        selected = nil
        attempt = nil
        pieces = start?.snapshot ?? pieces
        phase = .revealed
    }

    func retry() {
        attemptNumber += 1
        selected = nil
        attempt = nil
        pieces = start?.snapshot ?? pieces
        phase = .thinking
    }
}

// MARK: - W14 Mistake drill

struct MistakeDrillScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var drill: MistakeDrillModel
    /// Set for a sample mistake in the Mistakes preview: solving it is reported here instead of
    /// saved, and there is no game behind it to open.
    private let onSampleSolved: ((MistakeOccurrence) -> Void)?

    init(occurrence: MistakeOccurrence, onSampleSolved: ((MistakeOccurrence) -> Void)? = nil) {
        _drill = State(initialValue: MistakeDrillModel(occurrence: occurrence))
        self.onSampleSolved = onSampleSolved
    }

    private var occurrence: MistakeOccurrence { drill.occurrence }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Layout.contentInset)
                .padding(.bottom, 12)
            if drill.isAvailable {
                BoardView(presentation: drill.presentation, cornerRadius: 0) { square in
                    drill.tap(square) { markSolved() }
                }
                feedback
                    .padding(.horizontal, Layout.contentInset)
                    .padding(.top, 12)
            } else {
                EmptyState(symbol: "questionmark.square.dashed",
                           title: "This position could not be read",
                           message: "Open the game to see the move in context.")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Find a better move")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if drill.isAvailable {
                    NavigationLink(value: Route.explore(exploreStart)) {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .accessibilityLabel("Explore from this position")
                    .accessibilityHint("Play moves of your own from here, for both sides or against the engine")
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: drill.phase)
        .sensoryFeedback(trigger: drill.phase) { _, phase in
            switch phase {
            case .solved: return .success
            case .wrong: return .error
            default: return nil
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
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Solved")
                }
            }
            Text("You played the red arrow here against \(occurrence.opponent). Find a better move for \(drill.mover.name).")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The position the mistake was played in, to play on from freely.
    private var exploreStart: ExploreStart {
        ExploreStart(startFEN: occurrence.fenBefore, history: [], playerColor: occurrence.color,
                     orientation: occurrence.color,
                     origin: "Before \(occurrence.moveNumberLabel) \(occurrence.san)")
    }

    private func markSolved() {
        if let onSampleSolved { return onSampleSolved(occurrence) }
        try? model.statistics.markSolved(gameKey: occurrence.gameKey, ply: occurrence.ply)
        model.touch()
    }

    private var isSolvedNow: Bool {
        if case .solved = drill.phase { return true }
        return false
    }

    /// One line under the board, always the same height so the board never moves.
    private var feedback: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch drill.phase {
            case .thinking:
                Text("Tap a piece, then the square it should go to.")
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
                Text(solvedText(san: san, isEngineMove: isEngineMove))
                    .foregroundStyle(Palette.ink)
            case .revealed:
                Image(systemName: "lightbulb.fill").foregroundStyle(Palette.best)
                Text(drill.bestMoveSAN.map { "The engine plays \($0), the green arrow." }
                     ?? "The review kept no engine move for this position.")
                    .foregroundStyle(Palette.ink)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .lineLimit(3)
        .frame(minHeight: 64, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func wrongText(san: String, loss: Double?, isGameMove: Bool) -> String {
        if isGameMove { return "\(san) is the move from the game. Try another." }
        guard let loss else { return "\(san) is not the engine's move. Try again." }
        let severity = Scoring.severity(forLoss: loss)?.label.lowercased() ?? "error"
        return "\(san) is also \(severity == "inaccuracy" ? "an" : "a") \(severity). Try again."
    }

    private func solvedText(san: String, isEngineMove: Bool) -> String {
        if isEngineMove { return "Solved. \(san) is the engine's move." }
        if let best = drill.bestMoveSAN { return "Solved. \(san) holds the position; the engine's first choice was \(best)." }
        return "Solved. \(san) holds the position."
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
                case .solved:
                    primaryButton("Done") { dismiss() }
                case .revealed:
                    primaryButton("Try again") { drill.retry() }
                default:
                    Button { drill.reveal() } label: {
                        Text("Show answer")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(height: Layout.minimumTarget)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .disabled(!drill.isAvailable)
                }
            }
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Palette.background)
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
        .buttonStyle(.plain)
    }
}
