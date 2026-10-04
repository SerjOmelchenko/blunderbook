//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Everything a detector is allowed to look at. Detectors see only positions and engine lines —
/// never the result code, the clock or anything about the player — so a tag can always be
/// demonstrated on the board (§5).
struct DetectionContext {
    /// Position before the played move; the mover is to move.
    let boardBefore: ChessBoard
    let playedMove: Move
    /// Position after the played move; the opponent is to move.
    let boardAfter: ChessBoard
    /// The engine's choice in `boardBefore`, when it differs from the played move.
    let bestMove: Move?
    /// Engine line from `boardBefore`.
    let bestLine: [Move]
    /// Engine line from `boardAfter` — the opponent's best answer.
    let replyLine: [Move]
    let mover: PieceColor
    /// Scores in the mover's frame.
    let scoreBefore: EngineScore
    let scoreAfter: EngineScore
    let loss: Double
    let isBest: Bool
}

struct DetectionResult {
    var tags: [PatternTag] = []
    var consequence: Consequence = .evaluationLoss
    var explanation: String = ""
    /// Squares worth highlighting on the board when the evidence is shown.
    var evidenceSquares: [Int] = []
}

/// Evidence-based tagging. Every detector must be able to point at a line that demonstrates the
/// claim; when a line does not resolve or compensation is unclear, the detector stays silent and
/// the move falls back to a plain evaluation loss (§5).
enum PatternDetectors {

    static let maxForcingPlies = 12

    static func detect(_ context: DetectionContext) -> DetectionResult {
        var result = DetectionResult()

        let mateOutcome = mateTags(context)
        result.tags.append(contentsOf: mateOutcome.tags)

        let replyResolution = resolveForcingLine(from: context.boardAfter,
                                                 line: context.replyLine,
                                                 perspective: context.mover)
        let bestResolution = context.bestLine.isEmpty ? nil : resolveForcingLine(from: context.boardBefore,
                                                                                line: context.bestLine,
                                                                                perspective: context.mover)

        if let tag = undefendedPieceTag(context, resolution: replyResolution) { result.tags.append(tag) }
        if let tag = forkTag(context, replyResolution: replyResolution, bestResolution: bestResolution) {
            result.tags.append(tag)
        }
        if let tag = absolutePinTag(context, resolution: replyResolution) { result.tags.append(tag) }

        result.consequence = consequence(context,
                                         mateTags: mateOutcome.tags,
                                         replyResolution: replyResolution,
                                         bestResolution: bestResolution)
        result.explanation = explanation(context,
                                         consequence: result.consequence,
                                         replyResolution: replyResolution,
                                         bestResolution: bestResolution)
        result.evidenceSquares = evidenceSquares(context)
        return result
    }

    // MARK: - Mate tags

    private static func mateTags(_ context: DetectionContext) -> (tags: [PatternTag], allowedMateIn: Int?, missedMateIn: Int?) {
        var tags: [PatternTag] = []
        var allowed: Int?
        var missed: Int?

        let moverMatedBefore = moverIsMating(context.scoreBefore)
        let moverMatesAfter = moverIsMating(context.scoreAfter)
        let opponentMatedBefore = opponentIsMating(context.scoreBefore)
        let opponentMatesAfter = opponentIsMating(context.scoreAfter)

        // Allowed mate: the opponent now has a forced mate that was not there before.
        if opponentMatesAfter, !opponentMatedBefore {
            tags.append(.allowedMate)
            allowed = mateDistance(context.scoreAfter)
        }
        // Missed mate: a forced mate for the mover disappeared. A slower but still forced mate
        // is not a miss (§5).
        if moverMatedBefore, !moverMatesAfter {
            tags.append(.missedMate)
            missed = mateDistance(context.scoreBefore)
        }
        return (tags, allowed, missed)
    }

    /// True when the score says the perspective side mates, including a mate already delivered.
    private static func moverIsMating(_ score: EngineScore) -> Bool {
        switch score {
        case .centipawns: return false
        case .mate(let moves): return moves > 0
        case .checkmate(let won): return won
        }
    }

    private static func opponentIsMating(_ score: EngineScore) -> Bool {
        switch score {
        case .centipawns: return false
        case .mate(let moves): return moves < 0
        case .checkmate(let won): return !won
        }
    }

    private static func mateDistance(_ score: EngineScore) -> Int {
        switch score {
        case .mate(let moves): return abs(moves)
        case .checkmate: return 0
        case .centipawns: return 0
        }
    }

    // MARK: - Forcing-line resolution

    struct LineResolution {
        /// Material change in pawn units from the perspective side's point of view.
        var materialDelta: Int
        /// True when the line reached a quiet endpoint inside the ply budget.
        var resolved: Bool
        /// SAN of the line actually walked.
        var san: [String]
        /// The final board reached.
        var endPosition: ChessBoard
        var endsInMate: Bool
    }

    /// Follows checks, captures and promotions to a quiet endpoint within 12 plies (§5).
    /// A line that runs out of budget while still forcing is reported as unresolved, and callers
    /// must then omit any specific material claim.
    static func resolveForcingLine(from board: ChessBoard, line: [Move], perspective: PieceColor) -> LineResolution {
        let replay = board.copy()
        var san: [String] = []
        var resolved = true
        var played = 0

        for move in line {
            if played >= maxForcingPlies { resolved = false; break }
            guard replay.isLegalMove(move) else { resolved = false; break }
            let isForcing = replay.isCapture(move) || move.promotion != nil || givesCheck(replay, move)
            san.append(replay.san(for: move))
            replay.makeMove(move)
            played += 1
            // The first quiet move ends the tactical sequence, and so does a finished game.
            if !isForcing { break }
            if replay.terminalState() != nil { break }
        }

        let balance = replay.materialBalance()
        let startBalance = board.materialBalance()
        let signed = perspective == .white ? (balance - startBalance) : (startBalance - balance)
        let endsInMate = replay.terminalState() == .checkmate
        return LineResolution(materialDelta: signed, resolved: resolved, san: san, endPosition: replay, endsInMate: endsInMate)
    }

    private static func givesCheck(_ board: ChessBoard, _ move: Move) -> Bool {
        board.makeMove(move)
        let check = board.isInCheck
        board.unmakeMove()
        return check
    }

    // MARK: - Undefended piece

    /// The opponent's best line legally captures an undefended non-pawn piece and material stays
    /// down once the forcing captures resolve. Sound sacrifices with compensation are excluded by
    /// requiring a resolved, material-negative line.
    private static func undefendedPieceTag(_ context: DetectionContext, resolution: LineResolution) -> PatternTag? {
        guard let capture = context.replyLine.first else { return nil }
        let board = context.boardAfter
        guard board.isLegalMove(capture), board.isCapture(capture) else { return nil }
        guard let victim = board.piece(at: capture.toSquare), victim.kind != .pawn, victim.color == context.mover else { return nil }
        // Undefended: nothing of the victim's colour is guarding the square.
        guard board.attackers(of: capture.toSquare, by: context.mover).isEmpty else { return nil }
        guard resolution.resolved, resolution.materialDelta <= -2 else { return nil }
        return .undefendedPiece
    }

    // MARK: - Forks

    /// A fork needs both geometry and a demonstrated payoff: the moved piece must attack two or
    /// more non-pawn pieces (the king counts) and the line must win material or mate.
    private static func forkTag(_ context: DetectionContext,
                                replyResolution: LineResolution,
                                bestResolution: LineResolution?) -> PatternTag? {
        if let move = context.replyLine.first,
           context.boardAfter.isLegalMove(move),
           forkTargets(board: context.boardAfter, move: move) >= 2,
           replyResolution.endsInMate || (replyResolution.resolved && replyResolution.materialDelta <= -2) {
            return .allowedFork
        }
        if !context.isBest, let move = context.bestLine.first, let bestResolution,
           context.boardBefore.isLegalMove(move),
           forkTargets(board: context.boardBefore, move: move) >= 2,
           bestResolution.endsInMate || (bestResolution.resolved && bestResolution.materialDelta >= 2) {
            return .missedFork
        }
        return nil
    }

    private static func forkTargets(board: ChessBoard, move: Move) -> Int {
        let working = board.copy()
        let mover = working.sideToMove
        working.makeMove(move)
        guard let piece = working.piece(at: move.toSquare) else { return 0 }
        var count = 0
        for square in 0..<64 {
            guard let target = working.piece(at: square), target.color == mover.opposite else { continue }
            guard target.kind != .pawn else { continue }
            if attacks(board: working, from: move.toSquare, piece: piece, to: square) { count += 1 }
        }
        return count
    }

    private static func attacks(board: ChessBoard, from origin: Int, piece: Piece, to target: Int) -> Bool {
        switch piece.kind {
        case .pawn:
            return ChessTables.pawnAttacks[piece.color.rawValue][origin].contains(target)
        case .knight:
            return ChessTables.knightTargets[origin].contains(target)
        case .king:
            return ChessTables.kingTargets[origin].contains(target)
        case .bishop, .rook, .queen:
            let directions: Range<Int>
            switch piece.kind {
            case .bishop: directions = ChessTables.bishopDirections
            case .rook: directions = ChessTables.rookDirections
            default: directions = 0..<8
            }
            for direction in directions {
                for square in ChessTables.rays[direction][origin] {
                    if square == target { return true }
                    if board.squares[square] != 0 { break }
                }
            }
            return false
        }
    }

    // MARK: - Absolute pin

    /// A slider pins a piece against its king and the continuation demonstrates the cost.
    /// Relative pins are out of scope in v1.
    private static func absolutePinTag(_ context: DetectionContext, resolution: LineResolution) -> PatternTag? {
        guard let move = context.replyLine.first, context.boardAfter.isLegalMove(move) else { return nil }
        let working = context.boardAfter.copy()
        working.makeMove(move)
        guard let slider = working.piece(at: move.toSquare),
              [.bishop, .rook, .queen].contains(slider.kind) else { return nil }
        let kingSquare = working.kingSquare(of: context.mover)

        let directions: Range<Int>
        switch slider.kind {
        case .bishop: directions = ChessTables.bishopDirections
        case .rook: directions = ChessTables.rookDirections
        default: directions = 0..<8
        }
        var pinned = false
        for direction in directions {
            var firstBlocker: Int?
            for square in ChessTables.rays[direction][move.toSquare] {
                if working.squares[square] == 0 { continue }
                if firstBlocker == nil {
                    guard working.piece(at: square)?.color == context.mover else { break }
                    firstBlocker = square
                } else {
                    if square == kingSquare { pinned = true }
                    break
                }
            }
            if pinned { break }
        }
        guard pinned else { return nil }
        guard resolution.endsInMate || (resolution.resolved && resolution.materialDelta <= -1) else { return nil }
        return .allowedAbsolutePin
    }

    // MARK: - Consequence

    private static func consequence(_ context: DetectionContext,
                                    mateTags: [PatternTag],
                                    replyResolution: LineResolution,
                                    bestResolution: LineResolution?) -> Consequence {
        if mateTags.contains(.allowedMate) { return .allowsMate }
        if mateTags.contains(.missedMate) { return .missesForcedMate }
        if replyResolution.resolved, replyResolution.materialDelta <= -1 { return .losesMaterial }
        if let bestResolution, bestResolution.resolved,
           bestResolution.materialDelta >= 1, replyResolution.materialDelta < bestResolution.materialDelta {
            return .missesMaterialGain
        }
        // Only when nothing more specific was proven (§5).
        if Scoring.winPercent(context.scoreBefore) >= 80, Scoring.winPercent(context.scoreAfter) < 60 {
            return .lostWinningAdvantage
        }
        return .evaluationLoss
    }

    // MARK: - Explanations

    private static func explanation(_ context: DetectionContext,
                                    consequence: Consequence,
                                    replyResolution: LineResolution,
                                    bestResolution: LineResolution?) -> String {
        let opponent = context.mover.opposite.name
        let firstReply = replyResolution.san.first
        let bestSAN = context.bestMove.map { context.boardBefore.san(for: $0) }

        switch consequence {
        case .allowsMate:
            if case .checkmate = context.scoreAfter { return "This is checkmate." }
            if let mate = context.scoreAfter.mateDistance, mate < 0 {
                let distance = abs(mate)
                if let firstReply {
                    return distance == 1
                        ? "After \(firstReply), \(opponent) delivers checkmate."
                        : "After \(firstReply), \(opponent) forces mate in \(distance)."
                }
                return "\(opponent) now has a forced mate in \(distance)."
            }
            return "\(opponent) now has a forced mate."

        case .missesForcedMate:
            if let mate = context.scoreBefore.mateDistance, mate > 0, let bestSAN {
                return mate == 1
                    ? "\(bestSAN) was checkmate."
                    : "\(bestSAN) forced mate in \(mate)."
            }
            return "A forced mate was available."

        case .losesMaterial:
            let amount = materialPhrase(abs(replyResolution.materialDelta))
            if let firstReply {
                return "After \(firstReply), \(context.mover.name) is \(amount) down."
            }
            return "\(context.mover.name) ends up \(amount) down."

        case .missesMaterialGain:
            let amount = materialPhrase(abs(bestResolution?.materialDelta ?? 0))
            if let bestSAN {
                return "\(bestSAN) would have won \(amount)."
            }
            return "A line winning \(amount) was available."

        case .lostWinningAdvantage:
            if let bestSAN {
                return "A winning position slipped away. \(bestSAN) kept it."
            }
            return "A winning position slipped away."

        case .evaluationLoss:
            if context.isBest { return "The engine's first choice." }
            if let bestSAN {
                return "Reduces the position evaluation. The engine prefers \(bestSAN)."
            }
            return "Reduces the position evaluation."
        }
    }

    /// Pawn-unit material expressed the way a player would say it.
    static func materialPhrase(_ points: Int) -> String {
        switch points {
        case ..<1: return "nothing"
        case 1: return "a pawn"
        case 2: return "two pawns"
        case 3: return "a piece"
        case 4: return "a piece and a pawn"
        case 5: return "a rook"
        case 6: return "a rook and a pawn"
        case 9: return "a queen"
        default: return "\(points) points of material"
        }
    }

    private static func evidenceSquares(_ context: DetectionContext) -> [Int] {
        var squares: [Int] = []
        if let move = context.replyLine.first { squares.append(move.toSquare) }
        if let best = context.bestMove { squares.append(best.toSquare) }
        return Array(Set(squares))
    }
}
