//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// A position lifted out of a game to explore from.
struct ExploreStart: Hashable {
    var startFEN: String
    /// The real moves that reached the position, so repetitions and the halfmove clock still
    /// count in the explored line (a FEN alone cannot express them).
    var history: [Move]
    /// The side the person plays against the engine.
    var playerColor: PieceColor
    var orientation: PieceColor
    /// Where the position came from, as in "After 14… Nf6".
    var origin: String
}

/// A line of the person's own moves from a position in a game: "what if". Played for both sides,
/// or for one side against the engine's best replies.
///
/// Like the live lines, nothing here is stored, counted in statistics or charged to an allowance.
@MainActor
@Observable
final class ExploreModel {
    enum Mode: String, CaseIterable, Identifiable {
        /// The person moves for White and Black alike.
        case bothSides
        /// The person moves for their own side; the engine answers with its best move.
        case engine

        var id: String { rawValue }
        var title: String { self == .bothSides ? "Both sides" : "Against engine" }
    }

    let start: ExploreStart
    /// The game's position; nil when it could not be rebuilt.
    private let base: ChessBoard?
    /// The explored moves from the game's position, and their notation.
    private(set) var line: [Move] = []
    private(set) var sanLine: [String] = []
    /// How many of `line` are on the board: 0 is the game's position.
    private(set) var cursor = 0
    /// The position on the board.
    private(set) var board: ChessBoard
    private(set) var terminal: GameTerminal?
    private(set) var selected: Int?
    /// A promotion's moves, one per piece, while the person picks which.
    var promotionChoices: [Move] = []
    var orientation: PieceColor
    var mode: Mode {
        didSet { selected = nil }
    }

    init(start: ExploreStart, mode: Mode = .bothSides) {
        self.start = start
        self.mode = mode
        orientation = start.orientation
        if let board = ChessBoard(fen: start.startFEN) {
            for move in start.history {
                guard board.isLegalMove(move) else { break }
                board.makeMove(move)
            }
            base = board
        } else {
            base = nil
        }
        board = base?.copy() ?? ChessBoard()
        terminal = board.terminalState()
    }

    var isAvailable: Bool { base != nil }
    var isAtEnd: Bool { cursor == line.count }

    /// The side the engine plays, when the person plays against it.
    var engineColor: PieceColor? { mode == .engine ? start.playerColor.opposite : nil }

    /// The engine owes a move: its turn, at the end of the line, in a game still going.
    var isEngineTurn: Bool { board.sideToMove == engineColor && isAtEnd && terminal == nil }

    private var acceptsMoves: Bool { isAvailable && terminal == nil && board.sideToMove != engineColor }

    var presentation: BoardPresentation {
        var presentation = BoardPresentation.from(board: board,
                                                  orientation: orientation,
                                                  lastMove: cursor > 0 ? line[cursor - 1] : start.history.last,
                                                  isHypothetical: cursor > 0)
        presentation.selectedSquare = selected
        presentation.targetSquares = targets
        return presentation
    }

    /// Where the selected piece can go; a promotion's four moves share one square.
    private var targets: [Int] {
        guard let selected else { return [] }
        var seen = Set<Int>()
        return board.legalMoves().filter { $0.fromSquare == selected }.map(\.toSquare).filter { seen.insert($0).inserted }
    }

    // MARK: Moves

    /// Picks up a piece of the side to move, or plays the selected one to `square`.
    func tap(_ square: Int) {
        guard acceptsMoves else {
            selected = nil
            return
        }
        let legal = board.legalMoves()
        if let selected {
            let candidates = legal.filter { $0.fromSquare == selected && $0.toSquare == square }
            if candidates.count > 1 {
                self.selected = nil
                promotionChoices = candidates
                return
            }
            if let move = candidates.first {
                self.selected = nil
                play(move)
                return
            }
        }
        let canMove = legal.contains { $0.fromSquare == square }
        selected = canMove && selected != square ? square : nil
    }

    func promote(to kind: PieceKind) {
        let choice = promotionChoices.first { $0.promotion == kind }
        promotionChoices = []
        if let choice, board.isLegalMove(choice) { play(choice) }
    }

    /// Plays the engine's best move when it owes one and `lines` were calculated for this very
    /// position.
    func playEngineMove(from lines: LiveLinesModel) {
        guard isEngineTurn, !lines.isCalculating, lines.analysedFEN == board.fen,
              let move = lines.lines.first?.firstMove, board.isLegalMove(move) else { return }
        play(move)
    }

    /// Plays `move` on the board. A move that differs from the line's next one replaces the rest
    /// of the line with a new branch.
    private func play(_ move: Move) {
        if cursor < line.count, line[cursor] == move {
            go(to: cursor + 1)
            return
        }
        let san = board.san(for: move)
        line.removeSubrange(cursor...)
        sanLine.removeSubrange(cursor...)
        line.append(move)
        sanLine.append(san)
        cursor += 1
        board.makeMove(move)
        terminal = board.terminalState()
    }

    // MARK: Stepping

    /// Against the engine a step skips the engine's turns, so going back takes a move back and
    /// going forward replays it with the engine's answer.
    func step(_ delta: Int) {
        var target = cursor + delta
        if let engineColor {
            while target > 0, target < line.count, side(afterMoves: target) == engineColor { target += delta }
        }
        go(to: target)
    }

    func go(to index: Int) {
        guard let base else { return }
        cursor = min(max(0, index), line.count)
        selected = nil
        board = base.copy()
        for move in line.prefix(cursor) { board.makeMove(move) }
        terminal = board.terminalState()
    }

    /// Drops the explored line and returns to the game's position.
    func reset() {
        line = []
        sanLine = []
        go(to: 0)
    }

    var canStepBack: Bool { cursor > 0 }
    var canStepForward: Bool { cursor < line.count }

    private func side(afterMoves count: Int) -> PieceColor {
        let first = base?.sideToMove ?? .white
        return count % 2 == 0 ? first : first.opposite
    }

    /// The next move of the line when the board is part-way along it.
    var nextSAN: String? { cursor < sanLine.count ? sanLine[cursor] : nil }

    /// "14.Nf3" or "14…Nf6" for the first move, as on a scoresheet; Black's later moves go
    /// unnumbered.
    func chipLabel(_ index: Int) -> String {
        let first = base?.sideToMove ?? .white
        let plies = index + (first == .black ? 1 : 0)
        let number = (base?.fullmoveNumber ?? 1) + plies / 2
        if plies % 2 == 0 { return "\(number).\(sanLine[index])" }
        return index == 0 ? "\(number)\u{2026}\(sanLine[index])" : sanLine[index]
    }

    /// For the evaluation line once the position is over, when there are no engine lines.
    var terminalScore: EngineScore? {
        StockfishEngine.terminalScore(for: board)?.normalizedToWhite(mover: board.sideToMove)
    }
}

// MARK: - Explore

/// Continue a game from any position with moves that were never played. The board takes moves for
/// both sides, or for the person's side alone while the engine answers each with its best move.
/// The engine's live lines follow every position, and the line can be stepped through, branched
/// from any earlier move, or dropped to return to the game.
struct ExploreScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var explore: ExploreModel
    @State private var liveLines = LiveLinesModel()
    @Namespace private var chipSelection

    init(start: ExploreStart, mode: ExploreModel.Mode = .bothSides) {
        _explore = State(initialValue: ExploreModel(start: start, mode: mode))
    }

    private var stepAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.24) }

    var body: some View {
        Group {
            if !explore.isAvailable {
                EmptyState(symbol: "questionmark.square.dashed",
                           title: "This position could not be read",
                           message: "Go back to the game to keep reviewing it.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { rows }
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            } else {
                ReviewColumnLayout { rows }
            }
        }
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if explore.isAvailable { controls }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle("Explore")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Explore")
                        .font(.headline)
                    Text(explore.start.origin)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { explore.orientation = explore.orientation.opposite }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Flip board")
            }
        }
        .confirmationDialog("Promote to", isPresented: isChoosingPromotion, titleVisibility: .visible) {
            ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                Button(String(describing: kind).capitalized) { explore.promote(to: kind) }
            }
        }
        .animation(.smooth(duration: 0.25), value: explore.mode)
        .sensoryFeedback(.selection, trigger: explore.cursor)
        .task { refreshLines() }
        // Every change of position or mode recalculates the lines; their arrival is what lets
        // the engine answer.
        .onChange(of: positionKey) { _, _ in refreshLines() }
        .onChange(of: liveLines.isCalculating) { _, isCalculating in
            if !isCalculating { scheduleEngineMove() }
        }
        .onChange(of: isTooHot) { _, _ in refreshLines() }
        .onDisappear { liveLines.clear() }
    }

    private var positionKey: String { "\(explore.cursor)|\(explore.line.count)|\(explore.mode.rawValue)" }

    private var isChoosingPromotion: Binding<Bool> {
        Binding(get: { !explore.promotionChoices.isEmpty },
                set: { if !$0 { explore.promotionChoices = [] } })
    }

    /// The same column as the review: every row keeps its height, so the board never resizes.
    @ViewBuilder
    private var rows: some View {
        modePicker
            .padding(.horizontal, Layout.contentInset)
            .padding(.bottom, 8)
        EvaluationLine(score: barScore,
                       orientation: explore.orientation,
                       isSettled: explore.terminal != nil || !liveLines.lines.isEmpty)
            .padding(.horizontal, Layout.contentInset)
            .padding(.bottom, 6)
        BoardView(presentation: boardPresentation, cornerRadius: 0) { square in
            explore.tap(square)
        }
        .simultaneousGesture(swipeToStep)
        .layoutValue(key: IsReviewBoard.self, value: true)
        statusLine
            .padding(.horizontal, Layout.contentInset)
            .padding(.top, 8)
        if liveLines.isAvailable {
            EngineLinesPanel(lines: liveLines, isTooHot: isTooHot)
                .padding(.horizontal, Layout.contentInset)
                .padding(.top, 2)
        }
        moveStrip
            .padding(.horizontal, Layout.contentInset)
            .padding(.top, 4)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $explore.mode) {
            ForEach(ExploreModel.Mode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .accessibilityHint("Both sides: you move for White and Black. Against engine: the engine answers your moves.")
    }

    // MARK: Board

    /// The live lines' arrows, once their search for this position has finished. None while the
    /// engine is about to answer: its choice is about to be played, not suggested.
    private var boardPresentation: BoardPresentation {
        var presentation = explore.presentation
        if !liveLines.isCalculating, !isTooHot, !explore.isEngineTurn,
           liveLines.analysedFEN == explore.board.fen {
            presentation.lineArrows = liveLines.lines.compactMap(\.firstMove)
        }
        return presentation
    }

    private var barScore: EngineScore {
        explore.terminalScore ?? liveLines.lines.first?.score ?? .centipawns(0)
    }

    /// Swipe left for the next move of the line, right for the previous one.
    private var swipeToStep: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 40, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            }
    }

    private func step(_ delta: Int) {
        withAnimation(stepAnimation) { explore.step(delta) }
    }

    // MARK: Engine

    /// Heat stops the engine for reviews as well as bulk work (§7), so it stops here too.
    private var isTooHot: Bool { model.conditions.blockers.contains(.thermal) }

    private func refreshLines() {
        guard explore.isAvailable, !isTooHot, explore.terminal == nil else {
            liveLines.clear()
            return
        }
        liveLines.analyse(explore.board)
    }

    /// The engine's answer is the best of the lines it just calculated, played after a beat so
    /// the person's own move lands first.
    private func scheduleEngineMove() {
        guard explore.isEngineTurn else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            withAnimation(stepAnimation) { explore.playEngineMove(from: liveLines) }
        }
    }

    // MARK: Status

    /// One line under the board saying whose move it is, always two lines tall so the board
    /// never moves.
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let terminal = explore.terminal {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(Palette.brass)
                Text(terminalText(terminal))
                    .foregroundStyle(Palette.ink)
            } else if explore.mode == .engine, isTooHot {
                Text("The engine pauses while the phone is too warm.")
                    .foregroundStyle(Palette.brass)
            } else if explore.mode == .engine, !liveLines.isAvailable {
                Text("The engine could not be loaded, so it cannot answer. Play both sides instead.")
                    .foregroundStyle(Palette.loss)
            } else if explore.isEngineTurn {
                ProgressView().controlSize(.mini)
                Text("The engine is choosing a move for \(explore.board.sideToMove.name)…")
                    .foregroundStyle(Palette.inkSecondary)
            } else if let engineColor = explore.engineColor, explore.board.sideToMove == engineColor {
                Text(explore.nextSAN.map { "The engine played \($0) here. Step forward, or back to change your move." }
                     ?? "The engine's move.")
                    .foregroundStyle(Palette.inkSecondary)
            } else if explore.mode == .engine {
                Text("Your move as \(explore.start.playerColor.name). The engine answers with its best move.")
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                Text("\(explore.board.sideToMove.name) to move. Play any move for either side.")
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .frame(height: 38, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func terminalText(_ terminal: GameTerminal) -> String {
        switch terminal {
        case .checkmate: return "Checkmate. \(explore.board.sideToMove.opposite.name) wins."
        case .stalemate: return "Stalemate: a draw."
        case .insufficientMaterial: return "A draw: neither side has enough to mate."
        case .seventyFiveMoveRule: return "A draw by the 75-move rule."
        case .fivefoldRepetition: return "A draw by fivefold repetition."
        }
    }

    // MARK: Line

    private var moveStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    moveChip(index: 0, label: "Game", isSelected: explore.cursor == 0)
                        .id(0)
                    ForEach(Array(explore.sanLine.indices), id: \.self) { index in
                        moveChip(index: index + 1, label: explore.chipLabel(index),
                                 isSelected: explore.cursor == index + 1)
                            .id(index + 1)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: positionKey) { _, _ in
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(explore.cursor, anchor: .center) }
            }
        }
    }

    private func moveChip(index: Int, label: String, isSelected: Bool) -> some View {
        Button {
            withAnimation(stepAnimation) { explore.go(to: index) }
        } label: {
            HStack(spacing: 4) {
                if index == 0 {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(label)
                    .font(.footnote.weight(isSelected ? .semibold : .regular))
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
        .accessibilityLabel(index == 0 ? "The game's position" : label)
    }

    // MARK: Controls

    /// The review's row: step back far left, step forward far right, and the way back to the
    /// game's position well clear of both in the middle.
    private var controls: some View {
        HStack(spacing: 12) {
            stepButton(by: -1, symbol: "chevron.left",
                       label: explore.mode == .engine ? "Take back" : "Previous move",
                       isDisabled: !explore.canStepBack)
            Spacer(minLength: 0)
            Button {
                withAnimation(stepAnimation) { explore.reset() }
            } label: {
                Label("Back to game", systemImage: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: Layout.minimumTarget)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .disabled(explore.line.isEmpty)
            .opacity(explore.line.isEmpty ? 0.35 : 1)
            .accessibilityHint("Drops the explored moves and returns to the position from the game")
            Spacer(minLength: 0)
            stepButton(by: 1, symbol: "chevron.right", label: "Next move",
                       isDisabled: !explore.canStepForward)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
}
