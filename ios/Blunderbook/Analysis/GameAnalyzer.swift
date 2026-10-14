//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
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
/// A deep review (`DeepReview`) searches every position at the chosen level's budget and scores
/// each move from the pair of searches around it. Because no search depends on another, it spreads
/// them over every engine it is given, one position per engine at a time, and the result is the
/// same as on one engine.
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
    /// Extra engines a deep review shares its searches with, each on its own thread: those on
    /// performance cores, then those on efficiency cores.
    private let helpers: [ChessEngine]
    private let slowHelpers: [ChessEngine]
    private let cache: PositionCache?
    private let telemetry: AnalysisTelemetry.Channel?

    init(engine: ChessEngine,
         helpers: [ChessEngine] = [],
         slowHelpers: [ChessEngine] = [],
         cache: PositionCache? = nil,
         telemetry: AnalysisTelemetry.Channel? = nil) {
        self.engine = engine
        self.helpers = helpers
        self.slowHelpers = slowHelpers
        self.cache = cache
        self.telemetry = telemetry
    }

    /// - Parameters:
    ///   - deep: run a deep review rather than the standard analysis.
    ///   - reviewDepth: how deeply a deep review searches every position.
    ///   - onProgress: completed and total units of work, for display only.
    ///   - onPartial: a deep review's moves scored so far, in order, for display only: nothing is
    ///     saved until the whole game is done.
    func analyze(game: GameRecord,
                 deep: Bool = false,
                 reviewDepth: ReviewDepth = .default,
                 cancellation: CancellationToken,
                 onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil,
                 onPartial: ((_ moves: [MoveAnalysis]) -> Void)? = nil) throws -> GameAnalysis {
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
                                       nodes: reviewDepth.nodesPerPosition,
                                       cancellation: cancellation, onProgress: onProgress, onPartial: onPartial)
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
            evaluations.append(try evaluate(board, on: engine, nodes: AnalysisPolicy.nodesPerPosition, cancellation: cancellation))
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
                             nodes: Int,
                             cancellation: CancellationToken,
                             onProgress: ((Int, Int) -> Void)?,
                             onPartial: (([MoveAnalysis]) -> Void)?) throws -> GameAnalysis {
        let plies = moves.count
        let positions = plies + 1

        // Searches already made (`PositionCache`): this session's, at any move, so a review
        // stopped part way carries on; and the first positions of earlier games and of the named
        // openings.
        let signature = PositionCache.signature(of: engine)
        let startFEN = boards[0].fen
        let keys = boards.indices.map { PositionCache.key(moves.prefix($0)) }
        let cacheable = cache != nil && startFEN == ChessBoard.startFEN
            ? Array(0...min(PositionCache.maxPly, plies)) : []
        var roots: [Int: RootEvaluation] = [:]
        if let cache {
            let remembered = cache.remembered(engine: signature, nodes: nodes, startFEN: startFEN, keys: keys)
            for index in boards.indices { if let hit = remembered[keys[index]] { roots[index] = RootEvaluation(hit) } }
            let missing = cacheable.filter { roots[$0] == nil }
            let stored = cache.evaluations(engine: signature, nodes: nodes, keys: missing.map { keys[$0] })
            for index in missing { if let hit = stored[keys[index]] { roots[index] = RootEvaluation(hit) } }
        }

        // Known opening theory is not called an inaccuracy or a mistake (`Scoring.severity(_:isBook:)`).
        let book = OpeningBook.shared.trace(startFEN: boards[0].fen, moves: moves)

        // Each move is scored as soon as both positions around it are searched, and the moves
        // scored so far are passed on, so a review can be read while it runs.
        var scored: [Int: MoveAnalysis] = [:]
        func scoreReady(around index: Int) {
            for ply in [index - 1, index] where ply >= 0 && ply < plies && scored[ply] == nil {
                if let before = roots[ply], let after = roots[ply + 1] {
                    scored[ply] = scoreMove(ply: ply, moves: moves, boards: boards, before: before, after: after, book: book)
                }
            }
        }
        roots.keys.forEach(scoreReady(around:))
        if !scored.isEmpty { onPartial?(scored.values.sorted { $0.ply < $1.ply }) }
        onProgress?(roots.count, positions)

        // The slowest positions first, so no engine is left with a long search at the end: the
        // ones with most material, earliest first, which also fills a review from the start.
        let remaining = boards.indices.filter { roots[$0] == nil }.sorted {
            let (left, right) = (boards[$0].phaseMaterialWeight(), boards[$1].phaseMaterialWeight())
            return left != right ? left > right : $0 < $1
        }
        let alreadyKnown = roots.count
        _ = try evaluateAll(remaining, boards: boards, nodes: nodes, cancellation: cancellation) { done, index, root in
            roots[index] = root
            cache?.remember(engine: signature, nodes: nodes, startFEN: startFEN, key: keys[index], evaluation: CachedEvaluation(root))
            scoreReady(around: index)
            onPartial?(scored.values.sorted { $0.ply < $1.ply })
            onProgress?(alreadyKnown + done, positions)
        }

        // The first positions are kept for later games; ones already kept are left as they are.
        if let cache {
            let entries = cacheable.compactMap { index in roots[index].map { (key: keys[index], evaluation: CachedEvaluation($0)) } }
            cache.store(engine: signature, nodes: nodes, entries: entries)
        }

        if cancellation.isCancelled { throw AnalysisError.cancelled }
        var analysis = GameAnalysis(gameKey: game.gameKey, provenance: policy, status: .complete, nextPly: plies)
        analysis.moves = (0..<plies).map { ply in
            scored[ply] ?? scoreMove(ply: ply, moves: moves, boards: boards, before: roots[ply]!, after: roots[ply + 1]!, book: book)
        }
        (analysis.whiteAccuracy, analysis.blackAccuracy) = Scoring.gameAccuracies(analysis.moves)
        analysis.completedAt = Date()
        return analysis
    }

    /// One move of a deep review, from the searches of the positions before and after it.
    private func scoreMove(ply: Int,
                           moves: [Move],
                           boards: [ChessBoard],
                           before rootBefore: RootEvaluation,
                           after rootAfter: RootEvaluation,
                           book: OpeningTrace) -> MoveAnalysis {
        let boardBefore = boards[ply]
        let boardAfter = boards[ply + 1]
        let mover = boardBefore.sideToMove
        let playedMove = moves[ply]

        // The engine's own choice loses nothing.
        let playedIsBest = rootBefore.bestMove == playedMove
        let scoreBeforeMover = rootBefore.score
        let scoreAfterMover = playedIsBest ? rootBefore.score : rootAfter.score.negated()

        let loss = Scoring.loss(before: scoreBeforeMover, after: scoreAfterMover)
        let bestMove = rootBefore.bestMove
        let bestLine = rootBefore.line
        // When the played move was the engine's own choice, the continuation after it is the
        // rest of that same line — no independent search is allowed to invent a difference.
        let replyLine = playedIsBest ? Array(bestLine.dropFirst()) : rootAfter.line

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
                                confirmed: false,
                                loss: loss,
                                accuracy: Scoring.moveAccuracy(loss: loss),
                                severity: Scoring.severity(Scoring.severity(forLoss: loss), isBook: book.isBook(ply: ply)),
                                phase: Scoring.phase(beforePly: ply, board: boardBefore),
                                tags: detection.tags,
                                consequence: detection.consequence,
                                explanation: detection.explanation,
                                isBest: playedIsBest)
        telemetry?.recordPly()
        return MoveAnalysis(ply: ply,
                            mover: mover,
                            san: boardBefore.san(for: playedMove),
                            uci: playedMove.uci,
                            fenBefore: boardBefore.fen,
                            scoreBefore: scoreBeforeMover.normalizedToWhite(mover: mover),
                            scoreAfter: scoreAfterMover.normalizedToWhite(mover: mover),
                            lineSAN: sanSequence(from: boardAfter, moves: replyLine),
                            lineUCI: replyLine.map(\.uci),
                            depth: min(rootBefore.depth, rootAfter.depth),
                            nodes: rootBefore.nodes + rootAfter.nodes,
                            labels: labels)
    }

    // MARK: - Helpers

    /// Searches the given positions in the given order, each engine taking the next one as it
    /// frees up. Every search starts from a cleared engine, so which engine took which position
    /// never shows in the result. An efficiency-core engine stops taking positions once there are
    /// no more left than performance-core engines: it would take several times longer over one of
    /// them than a performance core that frees up meanwhile. The first error stops the others
    /// taking new positions and is rethrown; a cancellation wins over a cut-short search, as it
    /// does on one engine. `onEach` gets the number done so far and the search that just
    /// finished, one call at a time.
    private func evaluateAll(_ indices: [Int],
                             boards: [ChessBoard],
                             nodes: Int,
                             cancellation: CancellationToken,
                             onEach: (_ done: Int, _ index: Int, _ root: RootEvaluation) -> Void) throws -> [Int: RootEvaluation] {
        let fast = [engine] + helpers
        let engines = Array((fast + slowHelpers).prefix(max(1, indices.count)))
        let lock = NSLock()
        var next = 0
        var done = 0
        var results: [Int: RootEvaluation] = [:]
        var failure: Error?

        DispatchQueue.concurrentPerform(iterations: engines.count) { slot in
            let isSlow = slot >= fast.count
            while true {
                lock.lock()
                guard failure == nil, next < indices.count,
                      !isSlow || indices.count - next > fast.count else { lock.unlock(); return }
                let index = indices[next]
                next += 1
                lock.unlock()
                do {
                    let result = try evaluate(boards[index], on: engines[slot], nodes: nodes, cancellation: cancellation)
                    lock.lock()
                    results[index] = result
                    done += 1
                    onEach(done, index, result)
                    lock.unlock()
                } catch {
                    lock.lock()
                    if failure == nil || error is AnalysisError { failure = error }
                    lock.unlock()
                    return
                }
            }
        }
        if let failure { throw failure }
        return results
    }

    /// One position's search exactly as a review makes it, for building the bundled openings
    /// (`OpeningEvaluations.tsv`).
    func search(_ board: ChessBoard, nodes: Int) throws -> RootEvaluation {
        try evaluate(board, on: engine, nodes: nodes, cancellation: CancellationToken())
    }

    private func evaluate(_ board: ChessBoard, on engine: ChessEngine, nodes: Int, cancellation: CancellationToken) throws -> RootEvaluation {
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
