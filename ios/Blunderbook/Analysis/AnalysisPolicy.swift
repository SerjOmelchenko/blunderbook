//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The analysis every game gets.
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

/// The deep review of one game: the labelled analysis behind the game screen, the Mistakes tab and
/// the accuracy rings.
///
/// Changed 2026-10-12: every position is searched once at the chosen level's budget, the way
/// Lichess analyses a game, and each move is scored from the two searches around it. There is no
/// quick first pass and no confirmation search: a quick pass could only confirm errors it noticed,
/// and on real games it missed some that a deeper search sees at once. Reviews made before keep
/// their labels; each saved move records the nodes behind it.
///
/// Each move gets a loss, an accuracy, a severity, a phase, and the patterns a line on the board
/// demonstrates; the engine's preferred move and line are kept for the board arrow. A deep review
/// keeps every evaluation a standard one would, so it replaces one, and a standard analysis never
/// replaces a deep review.
enum DeepReview {
    static let identifier = "deep-v1"

    static let scoringIdentifier = "winpct-2026"
    static let taggerIdentifier = "detectors-2"

    static func isDeep(policyID: String) -> Bool { policyID == identifier }
}

/// How deeply a deep review searches: the nodes for every position. The person picks the level in
/// Settings, and it applies to reviews run after the change; reviews already saved keep their
/// labels. Measured 2026-10-11 on 9 real games against 8M-node searches, which found 158 errors:
/// 500k found 136 of them, 1.5M 141, 2M 144.
///
/// Searches stay node-limited, so a result never depends on the phone's speed, and neither does the
/// depth a budget reaches; only the time does.
///
/// The two deepest levels are Premium. Without it, a deeper choice stays saved but reviews run at
/// `deepestFree`, so subscribing again picks up where the person left off.
enum ReviewDepth: String, CaseIterable, Identifiable, Sendable {
    case quick
    case standard
    case deep
    case deepest

    /// Changed 2026-10-15 from Standard: about 3× faster, and on the 9 games above it found 136 of
    /// the 158 errors against Standard's 141 (100 with the same severity against 113).
    static let `default` = ReviewDepth.quick
    /// The deepest level the free plan runs.
    static let deepestFree = ReviewDepth.standard

    var id: String { rawValue }

    var requiresPremium: Bool {
        switch self {
        case .quick, .standard: return false
        case .deep, .deepest: return true
        }
    }

    /// The level reviews actually run at on a plan.
    func available(isPremium: Bool) -> ReviewDepth {
        isPremium || !requiresPremium ? self : Self.deepestFree
    }

    var title: String {
        switch self {
        case .quick: return "Quick"
        case .standard: return "Standard"
        case .deep: return "Deep"
        case .deepest: return "Deepest"
        }
    }

    /// Nodes for every position.
    var nodesPerPosition: Int {
        switch self {
        case .quick: return 500_000
        case .standard: return 1_500_000
        case .deep: return 3_000_000
        case .deepest: return 6_000_000
        }
    }

    /// Median depth over the 119 positions of a 59-move rapid game, with the bundled network
    /// (measured 2026-10-12; the same on the phone and the Mac). A sharp position reaches less.
    var typicalDepth: Int {
        switch self {
        case .quick: return 19
        case .standard: return 22
        case .deep: return 25
        case .deepest: return 28
        }
    }

    /// Time for a 40-move game (81 positions) on one performance core of an iPhone 16 Pro. Measured
    /// 2026-10-12 at 0.44 s a position for 500k, 1.81 s for 2M and 4.78 s for 5M; the other budgets
    /// are in proportion (about 0.95 s per million nodes).
    var timePerGame: String {
        switch self {
        case .quick: return "About 40 s a game"
        case .standard: return "About 2 min a game"
        case .deep: return "About 4 min a game"
        case .deepest: return "About 8 min a game"
        }
    }

    var nodesLabel: String {
        switch self {
        case .quick: return "500k nodes"
        case .standard: return "1.5M nodes"
        case .deep: return "3M nodes"
        case .deepest: return "6M nodes"
        }
    }

    /// Two lines for the Settings row: the search, then the time.
    var summary: String { "\(nodesLabel) per position · depth ~\(typicalDepth)\n\(timePerGame)" }
}

struct AnalysisProvenance: Hashable, Codable {
    var policyID: String
    var engineVersion: String
    var evaluationVersion: String
    var scoringVersion: String
    var taggerVersion: String
}

/// §5 severity ladder, used by deep reviews. Absent for non-errors; the star a move earns
/// otherwise is its `MoveGrade`.
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

    var sortOrder: Int {
        switch self {
        case .blunder: return 0
        case .mistake: return 1
        case .inaccuracy: return 2
        }
    }
}

/// The star a deep review gives a move (`MoveStar`): the engine's own choice, any other move
/// under the inaccuracy line, or one of the three errors. Book moves get none.
enum MoveGrade: Hashable {
    case best
    case good
    case inaccuracy
    case mistake
    case blunder

    init(severity: Severity?, isBest: Bool) {
        switch severity {
        case .inaccuracy: self = .inaccuracy
        case .mistake: self = .mistake
        case .blunder: self = .blunder
        case nil: self = isBest ? .best : .good
        }
    }

    var label: String {
        switch self {
        case .best: return "Best move"
        case .good: return "Good move"
        case .inaccuracy: return "Inaccuracy"
        case .mistake: return "Mistake"
        case .blunder: return "Blunder"
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
    ///
    /// `including` narrows the moves scored, such as to one phase, while the weights still come
    /// from the whole game's swings.
    static func gameAccuracies(_ moves: [MoveAnalysis],
                               including: (MoveAnalysis) -> Bool = { _ in true }) -> (white: Double?, black: Double?) {
        guard let last = moves.last else { return (nil, nil) }
        let series = moves.map { winPercent($0.scoreBefore) } + [winPercent(last.scoreAfter)]
        let window = max(2, min(8, moves.count / 10))
        // One window per move: the first few reuse the opening window, as Lichess does.
        let windows = Array(repeating: Array(series.prefix(window)), count: max(0, min(window, series.count) - 2))
            + (0...(series.count - window)).map { Array(series[$0..<($0 + window)]) }
        let weights = windows.map { max(0.5, min(12, standardDeviation($0))) }

        func accuracy(for color: PieceColor) -> Double? {
            let scored = moves.enumerated().compactMap { index, move in
                move.mover == color && including(move) ? move.labels.map { ($0.accuracy, weights[index]) } : nil
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
