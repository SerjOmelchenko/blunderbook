//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// One of the engine's best continuations from the position on screen.
struct EngineLine: Identifiable, Equatable {
    /// 0 for the best line.
    let rank: Int
    /// From White's point of view, like every score the app shows.
    let score: EngineScore
    /// Numbered notation, as in "12. Nf3 Nc6 13. Bb5".
    let notation: String
    /// The line's first move, drawn as an arrow on the board.
    var firstMove: Move? = nil
    var id: Int { rank }

    /// Formats a line played from `board`, numbering moves the way a scoresheet does.
    static func notation(for moves: [Move], from board: ChessBoard, maxPlies: Int) -> String {
        let replay = board.copy()
        var parts: [String] = []
        for (index, move) in moves.prefix(maxPlies).enumerated() {
            guard replay.isLegalMove(move) else { break }
            let san = replay.san(for: move)
            if replay.sideToMove == .white {
                parts.append("\(replay.fullmoveNumber). \(san)")
            } else if index == 0 {
                parts.append("\(replay.fullmoveNumber)\u{2026} \(san)")
            } else {
                parts.append(san)
            }
            replay.makeMove(move)
        }
        return parts.joined(separator: " ")
    }
}

/// The engine's top lines for whatever position the review is showing, recalculated as the
/// person steps through the game.
///
/// These are explanations for the screen, not analysis: they are never stored, never counted in
/// statistics, and use no allowance. They run on their own small engine so stepping through a
/// game never pauses the analysis queue, and that engine exists only while a review is open.
@MainActor
@Observable
final class LiveLinesModel {
    static let lineCount = 3
    static let nodeBudget = 400_000
    static let displayPlies = 8
    /// Stepping quickly through moves should not start a search for every one of them.
    static let settleDelay: TimeInterval = 0.15

    private(set) var lines: [EngineLine] = []
    /// The position `lines` were calculated for.
    private(set) var analysedFEN: String?
    private(set) var isCalculating = false
    /// False when the engine could not be loaded; the review still works without lines.
    private(set) var isAvailable = true

    private let worker = LiveLinesWorker()
    private var cancellation = CancellationToken()
    private var generation = 0

    /// Starts calculating `board`'s lines, abandoning any earlier position.
    func analyse(_ board: ChessBoard) {
        cancellation.cancel()
        let token = CancellationToken()
        cancellation = token
        generation += 1
        let current = generation
        let fen = board.fen
        isCalculating = true

        worker.search(board.copy(), token: token) { [weak self] result in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                switch result {
                case .lines(let lines): self.lines = lines; self.analysedFEN = fen
                case .unavailable: self.isAvailable = false; self.lines = []; self.analysedFEN = nil
                case .cancelled: return
                }
                self.isCalculating = false
            }
        }
    }

    /// Stops any search, for when the position is not worth calculating (the device is too hot,
    /// or the game is over).
    func clear() {
        cancellation.cancel()
        generation += 1
        lines = []
        analysedFEN = nil
        isCalculating = false
    }
}

/// Owns the live-lines engine on one serial queue, so it is created, used and released there.
private final class LiveLinesWorker: @unchecked Sendable {
    enum Result { case lines([EngineLine]), unavailable, cancelled }

    private let queue = DispatchQueue(label: "app.chessanalyser.live-lines", qos: .userInitiated)
    private var engine: StockfishEngine?
    private var loadFailed = false

    func search(_ board: ChessBoard, token: CancellationToken, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            Thread.sleep(forTimeInterval: LiveLinesModel.settleDelay)
            guard !token.isCancelled else { return completion(.cancelled) }

            if engine == nil, !loadFailed {
                // A smaller hash than the analysis engine: these searches are short.
                engine = StockfishEngine(hashSizeMiB: 16)
                loadFailed = engine == nil
            }
            guard let engine else { return completion(.unavailable) }

            let results = engine.searchLines(board: board,
                                             nodeBudget: LiveLinesModel.nodeBudget,
                                             count: LiveLinesModel.lineCount,
                                             cancellation: token)
            guard !token.isCancelled else { return completion(.cancelled) }

            let mover = board.sideToMove
            let lines = results.enumerated().map { rank, result in
                EngineLine(rank: rank,
                           score: result.score.normalizedToWhite(mover: mover),
                           notation: EngineLine.notation(for: result.principalVariation, from: board,
                                                         maxPlies: LiveLinesModel.displayPlies),
                           firstMove: result.principalVariation.first)
            }
            completion(.lines(lines))
        }
    }
}
