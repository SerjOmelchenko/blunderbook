//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// An engine evaluation, always read from the point of view of one named side.
enum EngineScore: Hashable, Codable {
    /// Centipawns, positive meaning better for the perspective side.
    case centipawns(Int)
    /// Distance to mate in *moves*, positive meaning the perspective side delivers it.
    /// Never zero: a mate already on the board is `.checkmate`.
    case mate(Int)
    /// The position is already checkmate. `perspectiveWon` is true when the perspective side
    /// delivered it, false when the perspective side is the one mated.
    case checkmate(perspectiveWon: Bool)

    var isMate: Bool {
        switch self {
        case .mate, .checkmate: return true
        case .centipawns: return false
        }
    }

    var mateDistance: Int? { if case .mate(let value) = self { return value }; return nil }

    var centipawnValue: Int? { if case .centipawns(let value) = self { return value }; return nil }

    func negated() -> EngineScore {
        switch self {
        case .centipawns(let value): return .centipawns(-value)
        case .mate(let value): return .mate(-value)
        case .checkmate(let won): return .checkmate(perspectiveWon: !won)
        }
    }

    /// Flips a score reported for `mover` into White's frame, which is how scores are stored.
    func normalizedToWhite(mover: PieceColor) -> EngineScore {
        mover == .white ? self : negated()
    }

    /// Flips a stored White-frame score into `mover`'s frame, which is how losses are scored.
    func fromWhite(to mover: PieceColor) -> EngineScore {
        mover == .white ? self : negated()
    }

    /// Ordering value used for comparisons and sorting. Mate scores dominate.
    var sortValue: Int {
        switch self {
        case .centipawns(let value): return max(-20_000, min(20_000, value))
        case .mate(let value): return value > 0 ? 100_000 - value : -100_000 - value
        case .checkmate(let won): return won ? 200_000 : -200_000
        }
    }

    /// Short display form: `+1.24`, `M4`, `-M2`.
    var displayText: String {
        switch self {
        case .centipawns(let value):
            let pawns = Double(value) / 100
            return String(format: "%@%.2f", value >= 0 ? "+" : "\u{2212}", abs(pawns))
        case .mate(let value):
            return value > 0 ? "M\(value)" : "\u{2212}M\(abs(value))"
        case .checkmate(let won):
            return won ? "#" : "\u{2212}#"
        }
    }

    /// Accessible spoken form for VoiceOver.
    var accessibleText: String {
        switch self {
        case .centipawns(let value):
            let pawns = abs(Double(value) / 100)
            if value == 0 { return "Level" }
            return String(format: "%@ by %.2f pawns", value > 0 ? "White ahead" : "Black ahead", pawns)
        case .mate(let value):
            return "Mate in \(abs(value)) for \(value > 0 ? "White" : "Black")"
        case .checkmate(let won):
            return won ? "Checkmate, White wins" : "Checkmate, Black wins"
        }
    }
}

/// Result of one root search.
struct SearchResult {
    var score: EngineScore
    var bestMove: Move?
    /// Up to 12 plies of principal variation (§5).
    var principalVariation: [Move]
    var nodes: Int
    var depth: Int
    /// True when the position was decided by rule and no search was needed.
    var isTerminal: Bool
    /// False when the search was stopped before its node budget ran out, or never ran. Such a
    /// result is not standard quality (§5) and is never stored.
    var isComplete = true

    static func terminal(_ score: EngineScore) -> SearchResult {
        SearchResult(score: score, bestMove: nil, principalVariation: [], nodes: 0, depth: 0, isTerminal: true)
    }
}

/// Cooperative cancellation shared between the coordinator and the engine worker.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        cancelled = false
    }
}

protocol ChessEngine: AnyObject {
    /// Identifier persisted with every analysis so results can be invalidated later.
    var engineIdentifier: String { get }
    /// Identifier of the evaluation weights, the equivalent of a pinned NNUE checksum.
    var evaluationIdentifier: String { get }
    /// Every other engine setting a search result depends on, such as threads and hash size.
    var searchConfigurationIdentifier: String { get }

    /// Forgets everything earlier searches learned. Analysis calls it at the start of every game,
    /// so a game's result never depends on which games the engine analysed before it.
    func newGame()

    /// Searches from the board's current position. Searches since the last `newGame()` inform
    /// this one, so the same searches in the same order always give the same results.
    func search(board: ChessBoard, nodeBudget: Int, cancellation: CancellationToken) -> SearchResult

    /// How urgently the following searches should run. Scheduling only: results never change.
    func setWorkload(_ workload: EngineWorkload)
}

/// Who is waiting for a search, and how much heat it may make.
enum EngineWorkload: Sendable, Equatable {
    /// A review the person asked for and is waiting on.
    case interactive
    /// Bulk work on the performance cores, at the same priority as a review.
    case bulk
    /// Bulk work kept on the efficiency cores: several times slower per engine and far cooler
    /// per node, so several of these run side by side.
    case bulkCool
}

extension ChessEngine {
    func setWorkload(_ workload: EngineWorkload) {}
}
