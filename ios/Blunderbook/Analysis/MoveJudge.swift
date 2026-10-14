//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Decides whether a move tried on the Mistakes tab fixes the mistake.
///
/// The engine's own choice always does. Any other move is searched, and it counts when it loses
/// less than an inaccuracy against the review's evaluation of the position: a move the review
/// itself would not have called an error. Like the live lines, these searches are never stored
/// and use no allowance, and they run on their own small engine.
final class MoveJudge: @unchecked Sendable {
    enum Verdict: Equatable {
        /// The move keeps the position; `loss` is in win-percentage points.
        case good(loss: Double)
        case bad(loss: Double)
        /// No engine to ask: only the engine's recorded choice can be accepted.
        case unknown
    }

    static let nodeBudget = 300_000

    private let queue = DispatchQueue(label: "app.chessanalyser.move-judge", qos: .userInitiated)
    private var engine: StockfishEngine?
    private var loadFailed = false

    /// - Parameters:
    ///   - board: the position after the tried move.
    ///   - mover: the side that tried it.
    ///   - before: the review's evaluation of the position before it, in White's frame.
    func judge(_ board: ChessBoard, mover: PieceColor, before: EngineScore) async -> Verdict {
        let board = board.copy()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if engine == nil, !loadFailed {
                    engine = StockfishEngine(hashSizeMiB: 16)
                    loadFailed = engine == nil
                }
                guard let engine else { return continuation.resume(returning: .unknown) }
                let result = engine.search(board: board, nodeBudget: Self.nodeBudget, cancellation: CancellationToken())
                guard result.isComplete || result.isTerminal else { return continuation.resume(returning: .unknown) }
                // Scored from the side to move after the tried move: the opponent.
                let after = result.score.normalizedToWhite(mover: board.sideToMove)
                let loss = Scoring.loss(before: before.fromWhite(to: mover), after: after.fromWhite(to: mover))
                continuation.resume(returning: Scoring.severity(forLoss: loss) == nil ? .good(loss: loss) : .bad(loss: loss))
            }
        }
    }
}
