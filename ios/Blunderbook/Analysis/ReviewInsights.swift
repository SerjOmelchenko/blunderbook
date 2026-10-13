//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

// MARK: - Clock

/// The game's clock, move by move, from the `[%clk]` comments Chess.com and Lichess write into
/// the PGN. A game without them, or a daily game, has no clock.
struct GameClock: Equatable {
    /// The mover's clock after each move, in seconds.
    let remaining: [TimeInterval?]
    /// How long each move took: the mover's previous clock (the starting time for their first
    /// move) less this one, plus the increment.
    let spent: [TimeInterval?]
    let base: TimeInterval
    let increment: TimeInterval

    /// Under this, the player is short of time: a minute in a ten-minute game, a tenth of the
    /// starting time in a faster one, never under ten seconds.
    var lowTime: TimeInterval { min(60, max(10, base / 10)) }

    /// Nil for a daily game, an unreadable time control, or a PGN with no clock comments.
    init?(clocks: [TimeInterval?], timeControl: String) {
        let parts = timeControl.split(separator: "+")
        guard !timeControl.contains("/"), let base = parts.first.flatMap({ TimeInterval($0) }), base > 0,
              clocks.contains(where: { $0 != nil }) else { return nil }
        let increment = parts.count > 1 ? TimeInterval(parts[1]) ?? 0 : 0
        self.base = base
        self.increment = increment
        self.remaining = clocks
        var spent: [TimeInterval?] = []
        for index in clocks.indices {
            // The same player's previous clock is two plies back.
            let previous: TimeInterval? = index >= 2 ? clocks[index - 2] : base
            if let previous, let now = clocks[index] {
                spent.append(max(0, previous - now + increment))
            } else {
                spent.append(nil)
            }
        }
        self.spent = spent
    }

    /// Both clocks once `plies` moves have been played: each player's clock after their last move.
    func clocks(afterPlies plies: Int) -> (white: TimeInterval?, black: TimeInterval?) {
        var white: TimeInterval? = base, black: TimeInterval? = base
        for index in 0..<min(plies, remaining.count) {
            if index % 2 == 0 { white = remaining[index] } else { black = remaining[index] }
        }
        return (white, black)
    }

    /// The first move by `color` that left them short of time; the ply index of the move.
    func lowTimeStart(for color: PieceColor, firstMover: PieceColor = .white) -> Int? {
        remaining.indices.first { index in
            (index % 2 == 0) == (color == firstMover) && (remaining[index] ?? .infinity) < lowTime
        }
    }

    /// "1:58", "0:07", "1:02:03".
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// A move's time under its chip: "4s" under a minute, "1:58" over.
    static func formatSpent(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds.rounded()))s" : format(seconds)
    }
}

// MARK: - Material

/// Material on the board, the way Lichess shows it beside each name: only what one side has more
/// of, so pieces traded off cancel out, and the difference in points.
struct MaterialBalance: Equatable {
    /// The kinds each side has more of, most valuable first, one entry per extra piece.
    var ahead: [PieceColor: [PieceKind]] = [:]
    /// White's material less Black's, in pawns.
    var difference = 0

    init(pieces: [Piece?]) {
        var counts: [PieceColor: [PieceKind: Int]] = [.white: [:], .black: [:]]
        for case let piece? in pieces { counts[piece.color, default: [:]][piece.kind, default: 0] += 1 }
        var white: [PieceKind] = [], black: [PieceKind] = []
        for kind in [PieceKind.queen, .rook, .bishop, .knight, .pawn] {
            let net = (counts[.white]?[kind] ?? 0) - (counts[.black]?[kind] ?? 0)
            if net > 0 { white += Array(repeating: kind, count: net) }
            if net < 0 { black += Array(repeating: kind, count: -net) }
            difference += net * kind.materialValue
        }
        ahead = [.white: white, .black: black]
    }

    /// "+2" beside the side that is ahead; nothing for the other or when level.
    func lead(for color: PieceColor) -> Int {
        color == .white ? max(0, difference) : max(0, -difference)
    }
}

// MARK: - Moments

/// What the review marks on a move beyond its own severity.
enum MoveMoment: Equatable {
    /// The opponent had just erred and this move let the chance go.
    case missedChance
    /// The opponent had just erred and this move took the chance.
    case punished
}

/// What a deep review says about the game as a whole, worked out on screen from the saved moves:
/// the moments worth stopping at, accuracy by phase, errors for each side, the biggest swing.
struct ReviewInsights: Equatable {
    /// By move index, for the tracked player's moves.
    var moments: [Int: MoveMoment] = [:]
    /// The tracked player's errors, missed chances and punished errors, in order: Next key moment
    /// steps through these. Move indices.
    var keyMoments: [Int] = []
    /// First move index of each phase the game reached.
    var phaseStarts: [GamePhase: Int] = [:]
    var phaseAccuracy: [GamePhase: (white: Double?, black: Double?)] = [:]
    var errorCounts: [PieceColor: [Severity: Int]] = [:]
    /// The tracked player's costliest error.
    var biggestError: Int?

    static let empty = ReviewInsights()

    /// An opponent error counts as a chance from a mistake up; an inaccuracy is too small to
    /// call one missed.
    static func isChance(_ severity: Severity?) -> Bool { severity == .mistake || severity == .blunder }
    /// A reply this close to the engine's best took the chance.
    static let punishLoss = 2.0

    /// `severity` gives each move's label with the book rule applied, as the review shows it.
    init(moves: [MoveAnalysis], player: PieceColor, severity: (MoveAnalysis) -> Severity?) {
        guard !moves.isEmpty else { return }
        var counts: [PieceColor: [Severity: Int]] = [.white: [:], .black: [:]]
        var worst: (index: Int, loss: Double)?
        for (index, move) in moves.enumerated() {
            if let label = severity(move) {
                counts[move.mover, default: [:]][label, default: 0] += 1
                if move.mover == player {
                    keyMoments.append(index)
                    let loss = move.labels?.loss ?? 0
                    if loss > (worst?.loss ?? -1) { worst = (index, loss) }
                }
            }
            if let phase = move.labels?.phase, phaseStarts[phase] == nil { phaseStarts[phase] = index }
            // The opponent's error, then this move's answer to it.
            guard move.mover == player, index > 0, Self.isChance(severity(moves[index - 1])),
                  moves[index - 1].mover != player else { continue }
            if Self.isChance(severity(move)) {
                moments[index] = .missedChance
            } else if (move.labels?.loss ?? .infinity) < Self.punishLoss {
                moments[index] = .punished
                keyMoments.append(index)
            }
        }
        keyMoments = Array(Set(keyMoments)).sorted()
        errorCounts = counts
        biggestError = worst?.index
        for phase in GamePhase.allCases where phaseStarts[phase] != nil {
            phaseAccuracy[phase] = Scoring.gameAccuracies(moves) { $0.labels?.phase == phase }
        }
    }

    static func == (lhs: ReviewInsights, rhs: ReviewInsights) -> Bool {
        lhs.moments == rhs.moments && lhs.keyMoments == rhs.keyMoments && lhs.phaseStarts == rhs.phaseStarts
            && lhs.errorCounts == rhs.errorCounts && lhs.biggestError == rhs.biggestError
            && GamePhase.allCases.allSatisfy { lhs.phaseAccuracy[$0]?.white == rhs.phaseAccuracy[$0]?.white
                && lhs.phaseAccuracy[$0]?.black == rhs.phaseAccuracy[$0]?.black }
    }

    init() {}
}

// MARK: - Targets

extension MoveAnalysis {
    /// The squares this move's patterns are about, for rings on the board. Rebuilt from the
    /// saved lines the way the review found the patterns; empty without labels or patterns.
    var patternTargets: [Int] {
        guard let labels, let tag = labels.tags.first,
              let boardBefore = ChessBoard(fen: fenBefore), let played = Move.fromUCI(uci),
              boardBefore.isLegalMove(played) else { return [] }
        let boardAfter = boardBefore.copy()
        boardAfter.makeMove(played)
        let bestLine = labels.bestLineUCI.compactMap(Move.fromUCI)
        let context = DetectionContext(boardBefore: boardBefore,
                                       playedMove: played,
                                       boardAfter: boardAfter,
                                       bestMove: labels.isBest ? nil : bestLine.first,
                                       bestLine: bestLine,
                                       replyLine: lineUCI.compactMap(Move.fromUCI),
                                       mover: mover,
                                       scoreBefore: scoreBefore.fromWhite(to: mover),
                                       scoreAfter: scoreAfter.fromWhite(to: mover),
                                       loss: labels.loss,
                                       isBest: labels.isBest)
        return PatternDetectors.targetSquares(for: tag, in: context)
    }
}
