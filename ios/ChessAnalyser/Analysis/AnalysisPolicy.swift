//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The one quality profile the app ships (§1: no Quick/Deep setting).
///
/// Every stored analysis records this identifier alongside the engine, evaluation, scoring and
/// tagger versions. Changing any number here means a new policy identifier, which keeps older
/// reviews readable while excluding them from current aggregates (§5).
///
/// **standard-v2**: every root search starts from a cleared hash, so a search depends only on
/// its position, history and budget. A game is analysed as one unit and saved when complete; an
/// interrupted game is analysed again from the start, which reproduces it exactly.
///
/// Tested alternative, not shipped: keep the engine's hash for a whole game and search its
/// positions from the last to the first, so what was found after a move informs the search
/// before it. Measured against 4M-node searches of every position in 48 real games, that matched
/// this policy's labels and game accuracy at 100k/350k nodes, 17% fewer than here, and lost
/// measurably below about 70% of the nodes. Too little to justify a new policy whose results
/// would replace every saved review; `keepsEngineMemory` switches it on, with a new identifier.
enum AnalysisPolicy {
    static let identifier = "standard-v2"

    /// Whether the engine keeps its hash between the searches of one game (see above).
    static let keepsEngineMemory = false
    /// Hash per analysis engine.
    static let hashSizeMiB = 64
    /// Nodes per root search.
    static let standardNodes = 100_000
    /// Nodes per root when a candidate error needs confirming.
    static let confirmationNodes = 500_000
    /// Win-percentage points of loss that trigger a confirmation pair.
    static let confirmationLossThreshold = 5.0
    /// Improvement in the after-evaluation that also triggers confirmation.
    static let confirmationImprovementThreshold = 5.0
    /// Principal-variation plies stored per root.
    static let maxStoredPVPlies = 12

    static let scoringIdentifier = "winpct-2024"
    static let taggerIdentifier = "detectors-1"

    /// Identity written into every analysis row.
    static func provenance(engine: ChessEngine) -> AnalysisProvenance {
        AnalysisProvenance(policyID: identifier,
                           engineVersion: engine.engineIdentifier,
                           evaluationVersion: engine.evaluationIdentifier,
                           scoringVersion: scoringIdentifier,
                           taggerVersion: taggerIdentifier)
    }

    /// Provenance of the engine this process is running, recorded with every analysis.
    ///
    /// Stockfish is the only engine, so until it has loaded there is nothing that can analyse.
    /// The placeholder exists because a game can be recorded as *failed* before any engine
    /// exists, and such a row carries no metrics.
    private(set) static var activeProvenance = AnalysisProvenance(policyID: identifier,
                                                                  engineVersion: "unavailable",
                                                                  evaluationVersion: "unavailable",
                                                                  scoringVersion: scoringIdentifier,
                                                                  taggerVersion: taggerIdentifier)

    static func setActiveEngine(_ engine: ChessEngine) {
        activeProvenance = provenance(engine: engine)
    }
}

struct AnalysisProvenance: Hashable, Codable {
    var policyID: String
    var engineVersion: String
    var evaluationVersion: String
    var scoringVersion: String
    var taggerVersion: String
}

/// §5 severity ladder. Absent for non-errors; there is no Excellent/Good/Brilliant taxonomy.
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

/// §5 scoring. All of it is evaluation-derived and deterministic: the same score pair always
/// produces the same loss, severity and accuracy.
enum Scoring {

    /// `W(cp) = 100 / (1 + exp(-0.00368208 × cp))`, cp bounded to ±10,000 for numeric safety.
    /// This is an evaluation-derived index, not a personalised win probability.
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

    /// `clamp(103.1668 × exp(-0.04354 × loss) − 3.1669, 0, 100)`, and exactly 100 at zero loss.
    static func moveAccuracy(loss: Double) -> Double {
        guard loss > 0 else { return 100 }
        let value = 103.1668 * exp(-0.04354 * loss) - 3.1669
        return max(0, min(100, value))
    }

    /// A colour's game accuracy is the arithmetic mean of its move accuracies.
    /// Explicitly this app's aggregation, not Lichess's weighted game score.
    static func gameAccuracy(_ moveAccuracies: [Double]) -> Double? {
        guard !moveAccuracies.isEmpty else { return nil }
        return moveAccuracies.reduce(0, +) / Double(moveAccuracies.count)
    }

    /// Endgame when the remaining §5 phase weights total 8 or less; otherwise opening for the
    /// first 20 plies, then middlegame. Evaluated on the position *before* the played move.
    static func phase(beforePly ply: Int, board: ChessBoard) -> GamePhase {
        if board.phaseMaterialWeight() <= 8 { return .endgame }
        return ply < 20 ? .opening : .middlegame
    }
}
