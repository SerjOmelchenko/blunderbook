//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
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

/// Turns one archived game into a saved review.
///
/// The shape of the work follows §5: every position along the game gets exactly one root search,
/// because the position *after* move *i* is the position *before* move *i+1*. Each ply is then
/// scored from the pair of roots that surround it, and confirmed at a larger budget when it looks
/// like an error. A position shared by two confirmed plies is confirmed once.
///
/// A game is analysed as one unit: every position from the last to the first, then the
/// confirmations, last ply first, and nothing is saved until the game is complete. An interrupted
/// game is analysed again from its first move. Under the shipped policy each search starts from a
/// cleared hash, so the order changes nothing; it matters only with
/// `AnalysisPolicy.keepsEngineMemory`, where each search builds on the ones before it.
final class GameAnalyzer {

    struct RootEvaluation {
        /// Score in the frame of the side to move in that position.
        var score: EngineScore
        var bestMove: Move?
        var line: [Move]
        var depth: Int
        var nodes: Int
        var isTerminal: Bool
    }

    /// A search stopped before its budget for a reason other than cancellation (the watchdog).
    private struct IncompleteSearch: Error {}

    private let engine: ChessEngine
    private let policy: AnalysisProvenance
    private let telemetry: AnalysisTelemetry.Channel?

    init(engine: ChessEngine, telemetry: AnalysisTelemetry.Channel? = nil) {
        self.engine = engine
        self.policy = AnalysisPolicy.provenance(engine: engine)
        self.telemetry = telemetry
    }

    /// - Parameter onProgress: completed and total units of work, for display only. Nothing is
    ///   saved before the game is complete.
    func analyze(game: GameRecord,
                 cancellation: CancellationToken,
                 onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil) throws -> GameAnalysis {

        guard game.isSupported else { throw AnalysisError.unsupportedGame }

        let parsed = PGNParser.parse(game.pgn)
        // A game whose notation cannot be fully read is a visible analysis failure, not a
        // review of whatever prefix happened to parse (§4).
        if let error = parsed.parseError { throw AnalysisError.malformedPGN(error) }
        if parsed.moves.isEmpty {
            // A completed game with no moves counts, and simply has no accuracy (§6).
            var analysis = GameAnalysis(gameKey: game.gameKey,
                                        provenance: policy,
                                        status: .complete,
                                        nextPly: 0,
                                        whiteAccuracy: nil,
                                        blackAccuracy: nil)
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

        do {
            return try analyzeOnce(game: game, moves: parsed.moves, boards: boards,
                                   cancellation: cancellation, onProgress: onProgress)
        } catch is IncompleteSearch {
            // A search the watchdog cut short leaves the engine's memory unlike an uninterrupted
            // run's, so the game starts over instead of carrying on. Once, then it fails (§7).
            do {
                return try analyzeOnce(game: game, moves: parsed.moves, boards: boards,
                                       cancellation: cancellation, onProgress: onProgress)
            } catch is IncompleteSearch {
                throw AnalysisError.engineFailure("a search did not finish, twice")
            }
        }
    }

    private func analyzeOnce(game: GameRecord,
                             moves: [Move],
                             boards: [ChessBoard],
                             cancellation: CancellationToken,
                             onProgress: ((Int, Int) -> Void)?) throws -> GameAnalysis {
        engine.newGame()
        let plies = moves.count
        let totalUnits = (plies + 1) + plies
        var completedUnits = 0

        // Every position at the standard budget, last first.
        var backward: [RootEvaluation] = []
        for index in stride(from: plies, through: 0, by: -1) {
            backward.append(try evaluate(boards[index], nodes: AnalysisPolicy.standardNodes, cancellation: cancellation))
            completedUnits += 1
            onProgress?(completedUnits, totalUnits)
        }
        let roots = Array(backward.reversed())

        // Each confirmed position is searched once: the position after ply i is the position
        // before ply i+1, so consecutive errors share it.
        var confirmations: [Int: RootEvaluation] = [:]
        func confirmedRoot(_ index: Int) throws -> RootEvaluation {
            if let known = confirmations[index] {
                telemetry?.recordSharedConfirmation()
                return known
            }
            let result = try evaluate(boards[index], nodes: AnalysisPolicy.confirmationNodes, cancellation: cancellation)
            confirmations[index] = result
            return result
        }

        var rows = [MoveAnalysis?](repeating: nil, count: plies)
        for ply in stride(from: plies - 1, through: 0, by: -1) {
            if cancellation.isCancelled { throw AnalysisError.cancelled }

            let boardBefore = boards[ply]
            let boardAfter = boards[ply + 1]
            let mover = boardBefore.sideToMove
            let playedMove = moves[ply]
            let playedSAN = boardBefore.san(for: playedMove)
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
            let severity = Scoring.severity(forLoss: loss)
            let accuracy = Scoring.moveAccuracy(loss: loss)
            let phase = Scoring.phase(beforePly: ply, board: boardBefore)

            let bestMove = classifyBefore.bestMove
            let bestLine = Array(classifyBefore.line.prefix(AnalysisPolicy.maxStoredPVPlies))
            // When the played move was the engine's own choice, the continuation after it is the
            // rest of that same line — no independent search is allowed to invent a difference.
            let replyLine = playedIsBest
                ? Array(bestLine.dropFirst())
                : Array(classifyAfter.line.prefix(AnalysisPolicy.maxStoredPVPlies))

            // Copies: a board is shared by the ply before it and the ply after it.
            let context = DetectionContext(boardBefore: boardBefore.copy(),
                                           playedMove: playedMove,
                                           boardAfter: boardAfter.copy(),
                                           bestMove: playedIsBest ? nil : bestMove,
                                           bestLine: bestLine,
                                           replyLine: replyLine,
                                           mover: mover,
                                           scoreBefore: scoreBeforeMover,
                                           scoreAfter: scoreAfterMover,
                                           loss: loss,
                                           isBest: playedIsBest)
            let detection = PatternDetectors.detect(context)

            rows[ply] = MoveAnalysis(ply: ply,
                                     mover: mover,
                                     san: playedSAN,
                                     uci: playedMove.uci,
                                     fenBefore: boardBefore.fen,
                                     scoreBefore: scoreBeforeMover.normalizedToWhite(mover: mover),
                                     scoreAfter: scoreAfterMover.normalizedToWhite(mover: mover),
                                     bestMoveSAN: playedIsBest ? nil : bestMove.map { boardBefore.san(for: $0) },
                                     bestLineSAN: sanSequence(from: boardBefore, moves: bestLine),
                                     bestLineUCI: bestLine.map(\.uci),
                                     replyLineSAN: sanSequence(from: boardAfter, moves: replyLine),
                                     replyLineUCI: replyLine.map(\.uci),
                                     depth: min(classifyBefore.depth, classifyAfter.depth),
                                     nodes: classifyBefore.nodes + classifyAfter.nodes,
                                     confirmed: confirmed,
                                     loss: loss,
                                     accuracy: accuracy,
                                     severity: severity,
                                     phase: phase,
                                     tags: detection.tags,
                                     consequence: detection.consequence,
                                     explanation: detection.explanation,
                                     isBest: playedIsBest)
            telemetry?.recordPly(confirmed: confirmed)
            completedUnits += 1
            onProgress?(completedUnits, totalUnits)
        }

        var analysis = GameAnalysis(gameKey: game.gameKey,
                                    provenance: policy,
                                    status: .complete,
                                    nextPly: plies,
                                    whiteAccuracy: nil,
                                    blackAccuracy: nil)
        analysis.moves = rows.compactMap { $0 }
        analysis.whiteAccuracy = Scoring.gameAccuracy(analysis.moves(by: .white).map(\.accuracy))
        analysis.blackAccuracy = Scoring.gameAccuracy(analysis.moves(by: .black).map(\.accuracy))
        analysis.completedAt = Date()
        return analysis
    }

    // MARK: - Helpers

    /// §5: confirm when the initial loss reaches 5 points, a mate appears or disappears, or the
    /// after-evaluation improves by more than 5 points.
    private func needsConfirmation(before: EngineScore, after: EngineScore) -> Bool {
        let beforePercent = Scoring.winPercent(before)
        let afterPercent = Scoring.winPercent(after)
        if beforePercent - afterPercent >= AnalysisPolicy.confirmationLossThreshold { return true }
        if before.isMate != after.isMate { return true }
        if after.isMate, before.isMate, (before.mateDistance ?? 0) * (after.mateDistance ?? 0) < 0 { return true }
        if afterPercent - beforePercent > AnalysisPolicy.confirmationImprovementThreshold { return true }
        return false
    }

    private func evaluate(_ board: ChessBoard, nodes: Int, cancellation: CancellationToken) throws -> RootEvaluation {
        if cancellation.isCancelled { throw AnalysisError.cancelled }
        // §5: independent roots, unless the policy keeps the engine's memory for the game.
        if !AnalysisPolicy.keepsEngineMemory { engine.newGame() }
        let started = Date()
        let result = engine.search(board: board.copy(), nodeBudget: nodes, cancellation: cancellation)
        // Positions decided by rule never reach the engine, so they would only dilute the rate.
        if !result.isTerminal {
            telemetry?.recordSearch(budget: nodes, seconds: Date().timeIntervalSince(started), nodes: result.nodes)
        }
        // A search cut short is not standard quality (§5): it is never scored.
        if !result.isTerminal, result.bestMove == nil || !result.isComplete {
            if cancellation.isCancelled { throw AnalysisError.cancelled }
            throw IncompleteSearch()
        }
        return RootEvaluation(result: result)
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

private extension GameAnalyzer.RootEvaluation {
    init(result: SearchResult) {
        self.init(score: result.score,
                  bestMove: result.bestMove,
                  line: result.principalVariation,
                  depth: result.depth,
                  nodes: result.nodes,
                  isTerminal: result.isTerminal)
    }
}
