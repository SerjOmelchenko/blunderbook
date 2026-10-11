//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The analysis every game gets, one at a time or a hundred at once.
///
/// **eval-v1**: Stockfish searches every position of a game once, from a cleared hash, and its
/// evaluation and line are stored as they come. Nothing else is computed or kept: no move labels,
/// no accuracy, no confirmation searches. How a move moved the evaluation bar is worked out on
/// screen from the two stored evaluations around it. A deeper three-line look runs live when a
/// game is opened (`LiveLinesModel`), and a game can be deep-reviewed on request (`DeepReview`).
///
/// Every stored analysis records this identifier with the engine and network versions. Any
/// complete analysis, whatever its policy, is shown: they all hold Stockfish evaluations of the
/// same positions, and earlier policies searched at least as deep.
enum AnalysisPolicy {
    static let identifier = "eval-v1"

    /// Hash per analysis engine.
    static let hashSizeMiB = 64
    /// Nodes per position.
    static let nodesPerPosition = 100_000
    /// Principal-variation plies stored per position.
    static let maxStoredPVPlies = 12

    static let scoringIdentifier = "eval-bar-1"
    static let taggerIdentifier = "none"

    /// Identity written into every analysis row.
    static func provenance(engine: ChessEngine, deep: Bool = false) -> AnalysisProvenance {
        AnalysisProvenance(policyID: deep ? DeepReview.identifier : identifier,
                           engineVersion: engine.engineIdentifier,
                           evaluationVersion: engine.evaluationIdentifier,
                           scoringVersion: deep ? DeepReview.scoringIdentifier : scoringIdentifier,
                           taggerVersion: deep ? DeepReview.taggerIdentifier : taggerIdentifier)
    }

    /// Provenance of the engine this process is running, recorded with every analysis.
    ///
    /// Stockfish is the only engine, so until it has loaded there is nothing that can analyse.
    /// The placeholder exists because a game can be recorded as *failed* before any engine
    /// exists, and such a row carries no evaluations.
    private(set) static var activeProvenance = AnalysisProvenance(policyID: identifier,
                                                                  engineVersion: "unavailable",
                                                                  evaluationVersion: "unavailable",
                                                                  scoringVersion: scoringIdentifier,
                                                                  taggerVersion: taggerIdentifier)

    static func setActiveEngine(_ engine: ChessEngine) {
        activeProvenance = provenance(engine: engine)
    }
}

/// The deep review of one game, run only when the person asks for it: the labelled analysis the
/// app ran for every game before eval-v1 (`standard-v2`).
///
/// Every position is searched at `standardNodes`. When a move looks like an error, both positions
/// around it are searched again at the chosen `ReviewDepth` before it is labelled. Each move then gets
/// a loss, an accuracy, a severity, a phase, and the patterns a line on the board demonstrates;
/// the engine's preferred move and line are kept for the board arrow. A deep review is a complete
/// review too: it keeps every evaluation a standard one would, so it replaces one, and a standard
/// analysis never replaces a deep review.
enum DeepReview {
    static let identifier = "deep-v1"

    /// Nodes per position.
    static let standardNodes = 100_000
    /// Win-percentage points of loss that trigger a confirmation pair.
    static let confirmationLossThreshold = 5.0
    /// Improvement in the after-evaluation that also triggers confirmation.
    static let confirmationImprovementThreshold = 5.0

    static let scoringIdentifier = "winpct-2026"
    static let taggerIdentifier = "detectors-2"

    static func isDeep(policyID: String) -> Bool { policyID == identifier }
}

/// How hard a deep review checks a move that looks like an error: the nodes for each of the two
/// confirmation searches around it. The person picks it in Settings, and it applies to reviews run
/// after the change; reviews already saved keep their labels.
///
/// Searches stay node-limited, so a result never depends on the phone's speed. The depth shown is
/// what that budget typically reaches on positions from real games; a sharp position reaches less.
///
/// The two deepest levels are Premium. Without it, a deeper choice stays saved but reviews run at
/// `deepestFree`, so subscribing again picks up where the person left off.
enum ReviewDepth: String, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case deep
    case deepest

    static let `default` = ReviewDepth.fast
    /// The deepest level the free plan runs.
    static let deepestFree = ReviewDepth.balanced

    var id: String { rawValue }

    var requiresPremium: Bool {
        switch self {
        case .fast, .balanced: return false
        case .deep, .deepest: return true
        }
    }

    /// The level reviews actually run at on a plan.
    func available(isPremium: Bool) -> ReviewDepth {
        isPremium || !requiresPremium ? self : Self.deepestFree
    }

    var confirmationNodes: Int {
        switch self {
        case .fast: return 500_000
        case .balanced: return 2_000_000
        case .deep: return 5_000_000
        case .deepest: return 10_000_000
        }
    }

    /// Median depth reached on 25 confirmed positions from real games (measured 2026-10-10).
    var typicalDepth: Int {
        switch self {
        case .fast: return 19
        case .balanced: return 23
        case .deep: return 26
        case .deepest: return 29
        }
    }

    var title: String { "Depth \(typicalDepth)" }

    /// Rough time for a deep review of a 65-ply game on a recent iPhone's performance core.
    var timePerGame: String {
        switch self {
        case .fast: return "about 10 s a game"
        case .balanced: return "about 30 s a game"
        case .deep: return "about 1 min a game"
        case .deepest: return "about 2 min a game"
        }
    }

    var nodesLabel: String {
        confirmationNodes >= 1_000_000
            ? "\(confirmationNodes / 1_000_000)M nodes"
            : "\(confirmationNodes / 1_000)k nodes"
    }
}

struct AnalysisProvenance: Hashable, Codable {
    var policyID: String
    var engineVersion: String
    var evaluationVersion: String
    var scoringVersion: String
    var taggerVersion: String
}

/// §5 severity ladder, used by deep reviews. Absent for non-errors; there is no
/// Excellent/Good/Brilliant taxonomy.
enum Severity: String, Codable, CaseIterable, Hashable {
    case inaccuracy
    case mistake
    case blunder

    var label: String {
        switch self {
        case .inaccuracy: return "Inaccuracy"
        case .mistake: return "Mistake"
        case .blunder: return "Blunder"
        }
    }

    /// Short marker used on the move list; always paired with text, never colour alone (§11).
    var marker: String {
        switch self {
        case .inaccuracy: return "?!"
        case .mistake: return "?"
        case .blunder: return "??"
        }
    }

    var sortOrder: Int {
        switch self {
        case .blunder: return 0
        case .mistake: return 1
        case .inaccuracy: return 2
        }
    }
}

enum GamePhase: String, Codable, CaseIterable, Hashable {
    case opening
    case middlegame
    case endgame

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// How an evaluation maps onto the evaluation bar, and, for deep reviews, the §5 scoring. All of
/// it is evaluation-derived and deterministic: the same score pair always produces the same loss,
/// severity and accuracy.
enum Scoring {
    /// White's share of the bar, 0–100: `100 / (1 + exp(-0.00368208 × cp))`, cp bounded to
    /// ±10,000 for numeric safety; mate fills the bar.
    static func winPercent(_ score: EngineScore) -> Double {
        switch score {
        case .centipawns(let value):
            let bounded = Double(max(-10_000, min(10_000, value)))
            return 100 / (1 + exp(-0.00368208 * bounded))
        case .mate(let moves):
            return moves > 0 ? 100 : 0
        case .checkmate(let won):
            return won ? 100 : 0
        }
    }

    /// Loss in win-percentage points, never negative (§5).
    static func loss(before: EngineScore, after: EngineScore) -> Double {
        max(0, winPercent(before) - winPercent(after))
    }

    /// App v1 thresholds: <5 unlabelled, 5–10 inaccuracy, 10–20 mistake, >=20 blunder.
    static func severity(forLoss loss: Double) -> Severity? {
        if loss >= 20 { return .blunder }
        if loss >= 10 { return .mistake }
        if loss >= 5 { return .inaccuracy }
        return nil
    }

    /// A book move is known theory, so it is not called an inaccuracy or a mistake. A blunder
    /// still is, because the book names traps too, such as Fool's Mate.
    static func severity(_ severity: Severity?, isBook: Bool) -> Severity? {
        isBook && severity != .blunder ? nil : severity
    }

    /// `clamp(103.1668 × exp(-0.04354 × loss) − 3.1669 + 1, 0, 100)`, and exactly 100 at zero
    /// loss. The +1 is Lichess's allowance for imperfect analysis.
    static func moveAccuracy(loss: Double) -> Double {
        guard loss > 0 else { return 100 }
        let value = 103.1668100711649 * exp(-0.04354415386753951 * loss) - 3.166924740191411 + 1
        return max(0, min(100, value))
    }

    /// Each colour's game accuracy, the same way for every game whatever site it came from:
    /// Lichess's published aggregation. A colour's score is the mean of
    ///
    /// - its move accuracies weighted by how much the position was swinging: the standard
    ///   deviation of White's win% over a window of `clamp(plies / 10, 2, 8)` positions,
    ///   clamped to 0.5–12, and
    /// - the harmonic mean of its move accuracies (each at least 1), so every bad move counts.
    ///
    /// A plain mean would hide errors: most moves score 95–100, so three blunders in thirty
    /// moves still average about 88. The positions are each move's stored before-score plus the
    /// last move's after-score; each move's accuracy is its own stored one.
    static func gameAccuracies(_ moves: [MoveAnalysis]) -> (white: Double?, black: Double?) {
        guard let last = moves.last else { return (nil, nil) }
        let series = moves.map { winPercent($0.scoreBefore) } + [winPercent(last.scoreAfter)]
        let window = max(2, min(8, moves.count / 10))
        // One window per move: the first few reuse the opening window, as Lichess does.
        let windows = Array(repeating: Array(series.prefix(window)), count: max(0, min(window, series.count) - 2))
            + (0...(series.count - window)).map { Array(series[$0..<($0 + window)]) }
        let weights = windows.map { max(0.5, min(12, standardDeviation($0))) }

        func accuracy(for color: PieceColor) -> Double? {
            let scored = moves.enumerated().compactMap { index, move in
                move.mover == color ? move.labels.map { ($0.accuracy, weights[index]) } : nil
            }
            guard !scored.isEmpty else { return nil }
            let weighted = scored.reduce(0) { $0 + $1.0 * $1.1 } / scored.reduce(0) { $0 + $1.1 }
            let harmonic = Double(scored.count) / scored.reduce(0) { $0 + 1 / max(1, $1.0) }
            return (weighted + harmonic) / 2
        }
        return (accuracy(for: .white), accuracy(for: .black))
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    /// Endgame when the remaining §5 phase weights total 8 or less; otherwise opening for the
    /// first 20 plies, then middlegame. Evaluated on the position *before* the played move.
    static func phase(beforePly ply: Int, board: ChessBoard) -> GamePhase {
        if board.phaseMaterialWeight() <= 8 { return .endgame }
        return ply < 20 ? .opening : .middlegame
    }
}
