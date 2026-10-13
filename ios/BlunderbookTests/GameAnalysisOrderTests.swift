//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import Blunderbook

/// A game is analysed as one unit on whichever engine is free. These are the properties that make
/// that safe: a result that never depends on the engine or on what it analysed before, and no
/// half-finished search ever stored.
final class GameAnalysisOrderTests: XCTestCase {

    /// Records every search it passes on. It can cancel the work as a given search starts, or
    /// report a given search as cut short, the way the watchdog does.
    private final class RecordingEngine: ChessEngine {
        let inner: StockfishEngine
        var searches: [(plies: Int, budget: Int)] = []
        var newGames = 0
        var cancelAtSearch: Int?
        var cutShortSearches: Set<Int> = []

        init(_ inner: StockfishEngine) { self.inner = inner }

        var engineIdentifier: String { inner.engineIdentifier }
        var evaluationIdentifier: String { inner.evaluationIdentifier }
        var searchConfigurationIdentifier: String { inner.searchConfigurationIdentifier }

        func newGame() {
            newGames += 1
            inner.newGame()
        }

        func search(board: ChessBoard, nodeBudget: Int, cancellation: CancellationToken) -> SearchResult {
            let index = searches.count
            if cancelAtSearch == index { cancellation.cancel() }
            searches.append((board.playedMoves.count, nodeBudget))
            var result = inner.search(board: board, nodeBudget: nodeBudget, cancellation: cancellation)
            if cutShortSearches.contains(index) { result.isComplete = false }
            return result
        }
    }

    private static let first: StockfishEngine? = StockfishEngine()
    private static let second: StockfishEngine? = StockfishEngine()

    private func engines() throws -> (StockfishEngine, StockfishEngine) {
        guard let first = Self.first, let second = Self.second else {
            throw XCTSkip("Stockfish unavailable: \(StockfishEngine.unavailableReason() ?? "unknown")")
        }
        return (first, second)
    }

    /// 3...Nf6?? allows Qxf7#, and 4.d3?? misses it: big swings both ways.
    private let missedMate = "[Event \"t\"]\n\n1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. d3 Nxh5"
    private let quiet = "[Event \"t\"]\n\n1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 Be7"

    private func makeGame(pgn: String, key: String) -> GameRecord {
        let parsed = PGNParser.parse(pgn)
        return GameRecord(gameKey: key, url: "https://example.com/\(key)", uuid: key, pgn: pgn,
                          startFEN: parsed.startFEN,
                          moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                          endTime: Date(), timeClass: .rapid, timeControl: "600", rules: "chess", rated: true,
                          white: GameSide(username: "white", rating: 1500, resultCode: "win"),
                          black: GameSide(username: "black", rating: 1500, resultCode: "resigned"),
                          eco: nil, ecoURL: nil, openingName: nil,
                          parseState: parsed.isValid ? .parsed : .malformed,
                          plyCount: parsed.moves.count)
    }

    func testDeepReviewSearchesEveryPositionOnceAtTheChosenDepth() throws {
        let recording = RecordingEngine(try engines().0)
        let game = makeGame(pgn: missedMate, key: "depth")
        let review = try GameAnalyzer(engine: recording).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                 cancellation: CancellationToken())

        XCTAssertEqual(recording.searches.map(\.budget),
                       Array(repeating: ReviewDepth.quick.nodesPerPosition, count: game.plyCount + 1),
                       "one search per position, even around the missed mate, and nothing else")
        XCTAssertEqual(recording.searches.map(\.plies).sorted(), Array(0...game.plyCount))
        XCTAssertTrue(review.moves.allSatisfy { $0.labels?.confirmed == false })
    }

    func testEveryPositionIsSearchedOnceFromAClearedEngine() throws {
        let recording = RecordingEngine(try engines().0)
        let game = makeGame(pgn: missedMate, key: "order")
        let review = try GameAnalyzer(engine: recording).analyze(game: game, cancellation: CancellationToken())

        let plies = game.plyCount
        XCTAssertEqual(recording.searches.map(\.plies), Array(0...plies), "each position once, nothing else")
        XCTAssertTrue(recording.searches.allSatisfy { $0.budget == AnalysisPolicy.nodesPerPosition })
        XCTAssertEqual(recording.newGames, plies + 1, "the engine forgets everything before every search")
        XCTAssertEqual(review.moves.count, plies)
        for (before, after) in zip(review.moves, review.moves.dropFirst()) {
            XCTAssertEqual(before.scoreAfter, after.scoreBefore, "one evaluation per position, shared by its two moves")
        }
    }

    func testAGameNeverDependsOnTheEngineOrWhatItAnalysedBefore() throws {
        let (first, second) = try engines()
        let game = makeGame(pgn: missedMate, key: "same")

        _ = try GameAnalyzer(engine: first).analyze(game: makeGame(pgn: quiet, key: "before"),
                                                    cancellation: CancellationToken())
        let afterAnotherGame = try GameAnalyzer(engine: first).analyze(game: game, cancellation: CancellationToken())
        let onAnotherEngine = try GameAnalyzer(engine: second).analyze(game: game, cancellation: CancellationToken())

        XCTAssertEqual(afterAnotherGame.moves, onAnotherEngine.moves, "every stored field, not just the scores")
    }

    func testADeepReviewSplitOverEnginesMatchesOneEngine() throws {
        let (first, second) = try engines()
        let game = makeGame(pgn: missedMate, key: "split")
        let alone = try GameAnalyzer(engine: first).analyze(game: game, deep: true, reviewDepth: .quick,
                                                            cancellation: CancellationToken())
        let split = try GameAnalyzer(engine: first, helpers: [second]).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                              cancellation: CancellationToken())
        XCTAssertEqual(alone.moves, split.moves, "every stored field, labels included")
        XCTAssertEqual(alone.whiteAccuracy, split.whiteAccuracy)
        XCTAssertEqual(alone.blackAccuracy, split.blackAccuracy)
    }

    func testCancellingMidSearchStopsWithNothingScored() throws {
        let recording = RecordingEngine(try engines().0)
        recording.cancelAtSearch = 3
        var progressAfterCancel = 0
        let token = CancellationToken()
        XCTAssertThrowsError(try GameAnalyzer(engine: recording)
            .analyze(game: makeGame(pgn: missedMate, key: "cancel"), cancellation: token) { _, _ in
                if token.isCancelled { progressAfterCancel += 1 }
            }) { error in
            guard case AnalysisError.cancelled = error else { return XCTFail("expected cancellation, got \(error)") }
        }
        XCTAssertEqual(progressAfterCancel, 0, "the search that was cut short counted for nothing")
        XCTAssertEqual(recording.searches.count, 4, "nothing was searched after the cancellation")
    }

    func testASearchCutShortStartsTheGameOverWithTheSameResult() throws {
        let (first, second) = try engines()
        let game = makeGame(pgn: missedMate, key: "watchdog")
        let clean = try GameAnalyzer(engine: second).analyze(game: game, cancellation: CancellationToken())

        let counting = RecordingEngine(first)
        _ = try GameAnalyzer(engine: counting).analyze(game: game, cancellation: CancellationToken())
        let searchesPerGame = counting.searches.count

        let recording = RecordingEngine(first)
        recording.cutShortSearches = [5]
        let restarted = try GameAnalyzer(engine: recording).analyze(game: game, cancellation: CancellationToken())
        XCTAssertEqual(recording.searches.count, 6 + searchesPerGame, "the game started over once, from its first search")
        XCTAssertEqual(restarted.moves, clean.moves)
    }

    func testTwoSearchesCutShortFailTheGame() throws {
        let recording = RecordingEngine(try engines().0)
        let game = makeGame(pgn: quiet, key: "fails")
        // The first attempt stops at its third search; the second attempt starts at index 3.
        recording.cutShortSearches = [2, 4]
        XCTAssertThrowsError(try GameAnalyzer(engine: recording).analyze(game: game, cancellation: CancellationToken())) { error in
            guard case AnalysisError.engineFailure = error else { return XCTFail("expected an engine failure, got \(error)") }
        }
    }
}
