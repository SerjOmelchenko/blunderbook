//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

enum AnalysisError: LocalizedError {
    case cancelled
    case unsupportedGame
    case malformedPGN(String)
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Analysis stopped"
        case .unsupportedGame: return "This game is not a standard chess game"
        case .malformedPGN(let detail): return "The game record could not be read: \(detail)"
        case .engineFailure(let detail): return "The engine stopped responding: \(detail)"
        }
    }
}

/// Turns one archived game into a saved review: Stockfish's evaluation of every position.
///
/// Every position along the game gets exactly one search, because the position *after* move *i*
/// is the position *before* move *i+1*. Each search starts from a cleared hash, so it depends only
/// on its position, its history and the node budget, and any engine gives the same result. Nothing
/// is saved until the game is complete; an interrupted game is analysed again from the start.
///
/// A deep review (`DeepReview`) then scores each move from the pair of searches around it, and
/// confirms it at a larger budget when it looks like an error. A position shared by two confirmed
/// moves is confirmed once.
final class GameAnalyzer {

    struct RootEvaluation {
        /// Score in the frame of the side to move in that position.
        var score: EngineScore
        var bestMove: Move?
        var line: [Move]
        var depth: Int
        var nodes: Int
    }

    /// A search stopped before its budget for a reason other than cancellation (the watchdog).
    private struct IncompleteSearch: Error {}

    private let engine: ChessEngine
    private let telemetry: AnalysisTelemetry.Channel?

    init(engine: ChessEngine, telemetry: AnalysisTelemetry.Channel? = nil) {
        self.engine = engine
        self.telemetry = telemetry
    }

    /// - Parameters:
    ///   - deep: run a deep review rather than the standard analysis.
    ///   - reviewDepth: how hard a deep review confirms a candidate error.
    ///   - onProgress: completed and total units of work, for display only.
    func analyze(game: GameRecord,
                 deep: Bool = false,
                 reviewDepth: ReviewDepth = .default,
                 cancellation: CancellationToken,
                 onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil) throws -> GameAnalysis {
        let policy = AnalysisPolicy.provenance(engine: engine, deep: deep)

        guard game.isSupported else { throw AnalysisError.unsupportedGame }

        let parsed = PGNParser.parse(game.pgn)
        // A game whose notation cannot be fully read is a visible analysis failure, not a
        // review of whatever prefix happened to parse (§4).
        if let error = parsed.parseError { throw AnalysisError.malformedPGN(error) }
        if parsed.moves.isEmpty {
            // A completed game with no moves counts, and simply has nothing to evaluate (§6).
            var analysis = GameAnalysis(gameKey: game.gameKey, provenance: policy, status: .complete, nextPly: 0)
            analysis.completedAt = Date()
            return analysis
        }

        guard let start = ChessBoard(fen: parsed.startFEN) else {
            throw AnalysisError.malformedPGN("Unreadable starting position")
        }
        // Every position of the game: before the first move through after the last.
        var boards = [start.copy()]
        for move in parsed.moves {
            start.makeMove(move)
            boards.append(start.copy())
        }

        let run: () throws -> GameAnalysis = { [self] in
            if deep {
                return try analyzeDeep(game: game, policy: policy, moves: parsed.moves, boards: boards,
                                       confirmationNodes: reviewDepth.confirmationNodes,
                                       cancellation: cancellation, onProgress: onProgress)
            }
            return try analyzeOnce(game: game, policy: policy, moves: parsed.moves, boards: boards,
                                   cancellation: cancellation, onProgress: onProgress)
        }
        do {
            return try run()
        } catch is IncompleteSearch {
            // A search the watchdog cut short is searched again with the whole game. Once, then
            // the game fails (§7).
            do {
                return try run()
            } catch is IncompleteSearch {
                throw AnalysisError.engineFailure("a search did not finish, twice")
            }
        }
    }

    private func analyzeOnce(game: GameRecord,
                             policy: AnalysisProvenance,
                             moves: [Move],
                             boards: [ChessBoard],
                             cancellation: CancellationToken,
                             onProgress: ((Int, Int) -> Void)?) throws -> GameAnalysis {
        var evaluations: [RootEvaluation] = []
        for board in boards {
            evaluations.append(try evaluate(board, nodes: AnalysisPolicy.nodesPerPosition, cancellation: cancellation))
            onProgress?(evaluations.count, boards.count)
        }

        var analysis = GameAnalysis(gameKey: game.gameKey, provenance: policy, status: .complete, nextPly: moves.count)
        for (ply, move) in moves.enumerated() {
            let boardBefore = boards[ply]
            let mover = boardBefore.sideToMove
            let before = evaluations[ply]
            let after = evaluations[ply + 1]
            // Each score is in the frame of the side to move there; after the move that is the
            // opponent, so the after-score flips once to reach the mover's frame.
            analysis.moves.append(MoveAnalysis(ply: ply,
                                               mover: mover,
                                               san: boardBefore.san(for: move),
                                               uci: move.uci,
                                               fenBefore: boardBefore.fen,
                                               scoreBefore: before.score.normalizedToWhite(mover: mover),
                                               scoreAfter: after.score.negated().normalizedToWhite(mover: mover),
                                               lineSAN: sanSequence(from: boards[ply + 1], moves: after.line),
                                               lineUCI: after.line.map(\.uci),
                                               depth: after.depth,
                                               nodes: after.nodes))
            telemetry?.recordPly()
        }
        analysis.completedAt = Date()
        return analysis
    }

    // MARK: - Deep review

    private func analyzeDeep(game: GameRecord,
                             policy: AnalysisProvenance,
                             moves: [Move],
                             boards: [ChessBoard],
                             confirmationNodes: Int,
                             cancellation: CancellationToken,
                             onProgress: ((Int, Int) -> Void)?) throws -> GameAnalysis {
        let plies = moves.count
        let totalUnits = (plies + 1) + plies
        var completedUnits = 0

        // Every position at the standard budget.
        var roots: [RootEvaluation] = []
        for board in boards {
            roots.append(try evaluate(board, nodes: DeepReview.standardNodes, cancellation: cancellation))
            completedUnits += 1
            onProgress?(completedUnits, totalUnits)
        }

        // Each confirmed position is searched once: the position after ply i is the position
        // before ply i+1, so consecutive errors share it.
        var confirmations: [Int: RootEvaluation] = [:]
        func confirmedRoot(_ index: Int) throws -> RootEvaluation {
            if let known = confirmations[index] { return known }
            let result = try evaluate(boards[index], nodes: confirmationNodes, cancellation: cancellation)
            confirmations[index] = result
            return result
        }

        // Known opening theory is not called an inaccuracy or a mistake (`Scoring.severity(_:isBook:)`).
        let book = OpeningBook.shared.trace(startFEN: boards[0].fen, moves: moves)

        var analysis = GameAnalysis(gameKey: game.gameKey, provenance: policy, status: .complete, nextPly: plies)
        for ply in 0..<plies {
            if cancellation.isCancelled { throw AnalysisError.cancelled }

            let boardBefore = boards[ply]
            let boardAfter = boards[ply + 1]
            let mover = boardBefore.sideToMove
            let playedMove = moves[ply]
            let rootBefore = roots[ply]
            let rootAfter = roots[ply + 1]

            let isBest = rootBefore.bestMove == playedMove
            var scoreBeforeMover = rootBefore.score
            var scoreAfterMover = isBest ? rootBefore.score : rootAfter.score.negated()
            var classifyBefore = rootBefore
            var classifyAfter = rootAfter
            var playedIsBest = isBest
            var confirmed = false

            if !isBest, needsConfirmation(before: scoreBeforeMover, after: scoreAfterMover) {
                classifyBefore = try confirmedRoot(ply)
                classifyAfter = try confirmedRoot(ply + 1)
                playedIsBest = classifyBefore.bestMove == playedMove
                scoreBeforeMover = classifyBefore.score
                scoreAfterMover = playedIsBest ? classifyBefore.score : classifyAfter.score.negated()
                confirmed = true
            }

            let loss = Scoring.loss(before: scoreBeforeMover, after: scoreAfterMover)
            let bestMove = classifyBefore.bestMove
            let bestLine = classifyBefore.line
            // When the played move was the engine's own choice, the continuation after it is the
            // rest of that same line — no independent search is allowed to invent a difference.
            let replyLine = playedIsBest ? Array(bestLine.dropFirst()) : classifyAfter.line

            // Copies: a board is shared by the ply before it and the ply after it.
            let detection = PatternDetectors.detect(DetectionContext(boardBefore: boardBefore.copy(),
                                                                     playedMove: playedMove,
                                                                     boardAfter: boardAfter.copy(),
                                                                     bestMove: playedIsBest ? nil : bestMove,
                                                                     bestLine: bestLine,
                                                                     replyLine: replyLine,
                                                                     mover: mover,
                                                                     scoreBefore: scoreBeforeMover,
                                                                     scoreAfter: scoreAfterMover,
                                                                     loss: loss,
                                                                     isBest: playedIsBest))

            let labels = MoveLabels(bestMoveSAN: playedIsBest ? nil : bestMove.map { boardBefore.san(for: $0) },
                                    bestLineSAN: sanSequence(from: boardBefore, moves: bestLine),
                                    bestLineUCI: bestLine.map(\.uci),
                                    confirmed: confirmed,
                                    loss: loss,
                                    accuracy: Scoring.moveAccuracy(loss: loss),
                                    severity: Scoring.severity(Scoring.severity(forLoss: loss), isBook: book.isBook(ply: ply)),
                                    phase: Scoring.phase(beforePly: ply, board: boardBefore),
                                    tags: detection.tags,
                                    consequence: detection.consequence,
                                    explanation: detection.explanation,
                                    isBest: playedIsBest)
            analysis.moves.append(MoveAnalysis(ply: ply,
                                               mover: mover,
                                               san: boardBefore.san(for: playedMove),
                                               uci: playedMove.uci,
                                               fenBefore: boardBefore.fen,
                                               scoreBefore: scoreBeforeMover.normalizedToWhite(mover: mover),
                                               scoreAfter: scoreAfterMover.normalizedToWhite(mover: mover),
                                               lineSAN: sanSequence(from: boardAfter, moves: replyLine),
                                               lineUCI: replyLine.map(\.uci),
                                               depth: min(classifyBefore.depth, classifyAfter.depth),
                                               nodes: classifyBefore.nodes + classifyAfter.nodes,
                                               labels: labels))
            telemetry?.recordPly()
            completedUnits += 1
            onProgress?(completedUnits, totalUnits)
        }

        (analysis.whiteAccuracy, analysis.blackAccuracy) = Scoring.gameAccuracies(analysis.moves)
        analysis.completedAt = Date()
        return analysis
    }

    /// §5: confirm when the initial loss reaches 5 points, a mate appears or disappears, or the
    /// after-evaluation improves by more than 5 points.
    private func needsConfirmation(before: EngineScore, after: EngineScore) -> Bool {
        let beforePercent = Scoring.winPercent(before)
        let afterPercent = Scoring.winPercent(after)
        if beforePercent - afterPercent >= DeepReview.confirmationLossThreshold { return true }
        if before.isMate != after.isMate { return true }
        if after.isMate, before.isMate, (before.mateDistance ?? 0) * (after.mateDistance ?? 0) < 0 { return true }
        if afterPercent - beforePercent > DeepReview.confirmationImprovementThreshold { return true }
        return false
    }

    // MARK: - Helpers

    private func evaluate(_ board: ChessBoard, nodes: Int, cancellation: CancellationToken) throws -> RootEvaluation {
        if cancellation.isCancelled { throw AnalysisError.cancelled }
        engine.newGame()
        let started = Date()
        let result = engine.search(board: board.copy(), nodeBudget: nodes, cancellation: cancellation)
        // Positions decided by rule never reach the engine, so they would only dilute the rate.
        if !result.isTerminal {
            telemetry?.recordSearch(budget: nodes, seconds: Date().timeIntervalSince(started), nodes: result.nodes)
        }
        // A search cut short is never stored (§5).
        if !result.isTerminal, result.bestMove == nil || !result.isComplete {
            if cancellation.isCancelled { throw AnalysisError.cancelled }
            throw IncompleteSearch()
        }
        return RootEvaluation(score: result.score,
                              bestMove: result.bestMove,
                              line: Array(result.principalVariation.prefix(AnalysisPolicy.maxStoredPVPlies)),
                              depth: result.depth,
                              nodes: result.nodes)
    }

    private func sanSequence(from board: ChessBoard, moves: [Move]) -> [String] {
        let replay = board.copy()
        var result: [String] = []
        for move in moves {
            guard replay.isLegalMove(move) else { break }
            result.append(replay.san(for: move))
            replay.makeMove(move)
        }
        return result
    }
}
