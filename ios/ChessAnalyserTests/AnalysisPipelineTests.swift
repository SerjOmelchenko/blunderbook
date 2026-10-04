//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import ChessAnalyser

final class AnalysisPipelineTests: XCTestCase {

    private func makeGame(pgn: String, key: String = "test") -> GameRecord {
        let parsed = PGNParser.parse(pgn)
        return GameRecord(gameKey: key,
                          url: "https://example.com/\(key)",
                          uuid: key,
                          pgn: pgn,
                          startFEN: parsed.startFEN,
                          moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                          endTime: Date(),
                          timeClass: .rapid,
                          timeControl: "600",
                          rules: "chess",
                          rated: true,
                          white: GameSide(username: "white", rating: 1500, resultCode: "win"),
                          black: GameSide(username: "black", rating: 1500, resultCode: "checkmated"),
                          eco: nil, ecoURL: nil, openingName: nil,
                          parseState: parsed.isValid ? .parsed : .malformed,
                          plyCount: parsed.moves.count)
    }

    /// Loading the 104 MB network takes a moment, so the whole suite shares one engine. This is
    /// the engine the app actually ships, so these tests exercise the real thing.
    private static let stockfish: StockfishEngine? = StockfishEngine()

    private var engine: StockfishEngine {
        guard let engine = Self.stockfish else {
            // Stockfish is the only engine; without it there is nothing to test.
            fatalError("Stockfish could not be loaded: \(StockfishEngine.unavailableReason() ?? "unknown reason")")
        }
        return engine
    }

    private var analyzer: GameAnalyzer { GameAnalyzer(engine: engine) }

    func testShippingEngineIsStockfish() throws {
        XCTAssertNotNil(Self.stockfish, StockfishEngine.unavailableReason() ?? "")
        XCTAssertEqual(engine.engineIdentifier, "stockfish-18")
        XCTAssertEqual(engine.evaluationIdentifier, "nn-c288c895ea92+nn-37f18f62d772")
        XCTAssertEqual(AnalysisPolicy.identifier, "standard-v2",
                       "a different engine means a different policy identifier")
    }

    func testStockfishIsReproducibleForAGivenNodeBudget() {
        let board = ChessBoard()
        let token = CancellationToken()
        engine.newGame()
        let first = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        engine.newGame()
        let second = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        // `newGame()` clears the hash and histories, which is what makes this hold. Without it,
        // the second search starts from what the first one learned.
        XCTAssertEqual(first.bestMove, second.bestMove)
        XCTAssertEqual(first.score, second.score)
        XCTAssertEqual(first.nodes, second.nodes)
        XCTAssertEqual(first.depth, second.depth)
    }

    func testBulkSearchesRunInTheBackgroundAndScoreTheSame() {
        let board = ChessBoard(fen: "r1bqkb1r/ppp2ppp/2n5/3np1N1/2B5/8/PPPP1PPP/RNBQK2R w KQkq - 0 6")!
        let token = CancellationToken()
        defer { engine.setWorkload(.interactive) }

        engine.setWorkload(.bulkCool)
        engine.newGame()
        let cool = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        // Background QoS is what lets the system keep the search on the efficiency cores.
        XCTAssertEqual(engine.lastSearchQoSClass, QOS_CLASS_BACKGROUND)

        engine.setWorkload(.bulk)
        engine.newGame()
        let bulk = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        XCTAssertEqual(engine.lastSearchQoSClass, QOS_CLASS_USER_INITIATED)

        engine.setWorkload(.interactive)
        engine.newGame()
        let interactive = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        XCTAssertEqual(engine.lastSearchQoSClass, QOS_CLASS_USER_INITIATED)

        // Searches are bounded by nodes, so running slower must never change the result.
        for result in [cool, bulk] {
            XCTAssertEqual(result.bestMove, interactive.bestMove)
            XCTAssertEqual(result.score, interactive.score)
            XCTAssertEqual(result.nodes, interactive.nodes)
            XCTAssertEqual(result.depth, interactive.depth)
        }
    }

    func testLiveLinesAreDistinctBestFirstAndLeaveSingleLineSearchUntouched() {
        let board = ChessBoard()
        let token = CancellationToken()
        engine.newGame()
        let before = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)

        let lines = engine.searchLines(board: board.copy(), nodeBudget: 200_000, count: 3, cancellation: token)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Set(lines.compactMap(\.bestMove)).count, 3, "three different first moves")
        let scores = lines.map(\.score.sortValue)
        XCTAssertEqual(scores, scores.sorted(by: >), "best line first")

        // Stored analysis is single-line: a live search must not leave the engine in MultiPV.
        engine.newGame()
        let after = engine.search(board: board.copy(), nodeBudget: 100_000, cancellation: token)
        XCTAssertEqual(before.bestMove, after.bestMove)
        XCTAssertEqual(before.score, after.score)
        XCTAssertEqual(before.nodes, after.nodes)
    }

    func testLineNotationNumbersMovesLikeAScoresheet() {
        let board = ChessBoard()
        board.makeMove(Move.fromUCI("e2e4")!)
        let line = ["e7e5", "g1f3", "b8c6"].compactMap(Move.fromUCI)
        XCTAssertEqual(EngineLine.notation(for: line, from: board, maxPlies: 8), "1\u{2026} e5 2. Nf3 Nc6")
        XCTAssertEqual(EngineLine.notation(for: line, from: board, maxPlies: 2), "1\u{2026} e5 2. Nf3")
    }

    func testStockfishSeesRepetitionThroughTheMoveHistory() {
        // A FEN alone cannot express repetition (§5), so the bridge sends the whole history.
        let board = ChessBoard()
        for san in ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1"] {
            board.makeMove(board.move(fromSAN: san)!)
        }
        XCTAssertEqual(board.playedMoves.count, 7)
        XCTAssertEqual(board.initialFEN, ChessBoard.startFEN)
        engine.newGame()
        let result = engine.search(board: board, nodeBudget: 60_000, cancellation: CancellationToken())
        XCTAssertNotNil(result.bestMove)
    }

    func testStockfishReportsTerminalPositions() {
        let mated = ChessBoard(fen: "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")!
        let result = engine.search(board: mated, nodeBudget: 10_000, cancellation: CancellationToken())
        XCTAssertTrue(result.isTerminal)
        XCTAssertEqual(result.score, .checkmate(perspectiveWon: false))
    }

    func testStockfishFindsAForcedMate() {
        let board = ChessBoard(fen: "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq g3 0 2")!
        engine.newGame()
        let result = engine.search(board: board, nodeBudget: 50_000, cancellation: CancellationToken())
        XCTAssertEqual(result.bestMove, Move.fromUCI("d8h4"))
        XCTAssertEqual(result.score, .mate(1))
    }

    func testFoolsMateIsScoredAsABlunderThatAllowsMate() throws {
        let game = makeGame(pgn: "[Event \"t\"]\n[Result \"0-1\"]\n\n1. f3 e5 2. g4 Qh4# 0-1")
        let analysis = try analyzer.analyze(game: game, cancellation: CancellationToken())

        XCTAssertEqual(analysis.status, .complete)
        XCTAssertEqual(analysis.moves.count, 4)

        let blunder = analysis.moves[2]
        XCTAssertEqual(blunder.san, "g4")
        XCTAssertEqual(blunder.severity, .blunder)
        XCTAssertTrue(blunder.tags.contains(.allowedMate))
        XCTAssertEqual(blunder.consequence, .allowsMate)
        XCTAssertTrue(blunder.explanation.contains("checkmate"), "the explanation states what the line shows")

        let mate = analysis.moves[3]
        XCTAssertEqual(mate.loss, 0, accuracy: 0.0001, "the engine's own choice cannot lose anything")
        XCTAssertEqual(mate.accuracy, 100, accuracy: 0.0001)
    }

    func testWhiteAndBlackAreScoredSymmetrically() throws {
        let black = try analyzer.analyze(game: makeGame(pgn: "[Event \"t\"]\n\n1. f3 e5 2. g4 Qh4# 0-1", key: "b"),
                                         cancellation: CancellationToken())
        let white = try analyzer.analyze(game: makeGame(pgn: "[Event \"t\"]\n\n1. e4 f6 2. d4 g5 3. Qh5# 1-0", key: "w"),
                                         cancellation: CancellationToken())
        XCTAssertEqual(black.moves[2].severity, .blunder)
        XCTAssertEqual(white.moves[3].severity, .blunder, "the mirrored blunder must score the same")
        XCTAssertTrue(white.moves[3].tags.contains(.allowedMate))
    }

    func testZeroMoveGameCompletesWithoutAccuracy() throws {
        let analysis = try analyzer.analyze(game: makeGame(pgn: "[Event \"t\"]\n[Result \"1-0\"]\n\n1-0", key: "empty"),
                                            cancellation: CancellationToken())
        XCTAssertEqual(analysis.status, .complete)
        XCTAssertTrue(analysis.moves.isEmpty)
        XCTAssertNil(analysis.whiteAccuracy, "no moves means accuracy is unavailable, never zero")
    }

    func testMalformedGameFailsWithoutInventingMetrics() {
        // The first move is legal, but the record as a whole cannot be read. No partial review
        // is published from the prefix.
        let game = makeGame(pgn: "[Event \"t\"]\n\n1. e4 Qz9", key: "bad")
        XCTAssertThrowsError(try analyzer.analyze(game: game, cancellation: CancellationToken())) { error in
            guard case AnalysisError.malformedPGN = error else {
                return XCTFail("expected a malformed-PGN error, got \(error)")
            }
        }
    }

    func testCancellationStopsWithoutPublishingMetrics() {
        let token = CancellationToken()
        token.cancel()
        let game = makeGame(pgn: "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6", key: "cancel")
        XCTAssertThrowsError(try analyzer.analyze(game: game, cancellation: token)) { error in
            guard case AnalysisError.cancelled = error else {
                return XCTFail("expected cancellation, got \(error)")
            }
        }
    }

    func testAnInterruptedGameStartsOverAndReachesTheSameResult() throws {
        // Short but not quiet: 3...Bc5?? is a blunder that triggers a confirmation pair, and the
        // game ends in mate.
        let pgn = "[Event \"t\"]\n\n1. e4 e5 2. Bc4 Nc6 3. Qh5 Bc5 4. Qxf7# 1-0"
        let game = makeGame(pgn: pgn, key: "restart")
        let full = try analyzer.analyze(game: game, cancellation: CancellationToken())
        XCTAssertEqual(full.moves.count, 7)
        XCTAssertTrue(full.moves.contains { $0.confirmed }, "the fixture must exercise confirmation")

        for stopAt in [2, 8, 12] {
            let token = CancellationToken()
            XCTAssertThrowsError(try analyzer.analyze(game: game, cancellation: token) { completed, _ in
                if completed == stopAt { token.cancel() }
            }) { error in
                guard case AnalysisError.cancelled = error else { return XCTFail("expected cancellation, got \(error)") }
            }
            let again = try analyzer.analyze(game: game, cancellation: CancellationToken())
            XCTAssertEqual(again.moves, full.moves, "stopped after \(stopAt) units, then analysed from the start")
            XCTAssertEqual(again.whiteAccuracy, full.whiteAccuracy)
            XCTAssertEqual(again.blackAccuracy, full.blackAccuracy)
        }
    }

    func testProgressCoversEveryPositionThenEveryPly() throws {
        var progress: [Int] = []
        var totals = Set<Int>()
        let game = makeGame(pgn: "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6", key: "progress")
        _ = try analyzer.analyze(game: game, cancellation: CancellationToken()) { completed, total in
            progress.append(completed)
            totals.insert(total)
        }
        // Seven positions searched, then six plies scored.
        XCTAssertEqual(progress, Array(1...13))
        XCTAssertEqual(totals, [13])
    }

    func testGameAccuracyMatchesTheMeanOfItsMoves() throws {
        let game = makeGame(pgn: "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6", key: "accuracy")
        let analysis = try analyzer.analyze(game: game, cancellation: CancellationToken())
        let whiteMoves = analysis.moves(by: .white).map(\.accuracy)
        XCTAssertEqual(analysis.whiteAccuracy!,
                       whiteMoves.reduce(0, +) / Double(whiteMoves.count),
                       accuracy: 0.0001)
    }

    func testResultCodeNeverReplacesTheEvaluation() throws {
        // A quiet, balanced game that White lost on time. The recorded result must not turn the
        // final evaluation into a mate, and it must not move the evaluation at all.
        var game = makeGame(pgn: "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6", key: "timeout")
        game.white = GameSide(username: "white", rating: 1500, resultCode: "timeout")
        game.black = GameSide(username: "black", rating: 1500, resultCode: "win")
        XCTAssertEqual(game.white.outcome, .loss)
        XCTAssertEqual(game.black.outcome, .win)

        let analysis = try analyzer.analyze(game: game, cancellation: CancellationToken())
        let last = analysis.moves.last!
        XCTAssertFalse(last.scoreAfter.isMate, "a clock loss is not checkmate")

        // The same moves with the opposite result code must score identically.
        var mirrored = game
        mirrored.gameKey = "timeout-2"
        mirrored.white = GameSide(username: "white", rating: 1500, resultCode: "win")
        mirrored.black = GameSide(username: "black", rating: 1500, resultCode: "resigned")
        let other = try analyzer.analyze(game: mirrored, cancellation: CancellationToken())
        XCTAssertEqual(analysis.whiteAccuracy, other.whiteAccuracy)
        XCTAssertEqual(analysis.moves.map(\.scoreAfter), other.moves.map(\.scoreAfter))
    }
}
