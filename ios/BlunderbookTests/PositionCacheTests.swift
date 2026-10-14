//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import Blunderbook

/// A cached search is the search the engine would make, so a review that uses one is identical to
/// one that does not; and a review shown while it runs adds up to the finished one.
final class PositionCacheTests: XCTestCase {

    private final class CountingEngine: ChessEngine {
        let inner: StockfishEngine
        var searches = 0
        var cancelAtSearch: (number: Int, token: CancellationToken)?
        init(_ inner: StockfishEngine) { self.inner = inner }
        var engineIdentifier: String { inner.engineIdentifier }
        var evaluationIdentifier: String { inner.evaluationIdentifier }
        var searchConfigurationIdentifier: String { inner.searchConfigurationIdentifier }
        func newGame() { inner.newGame() }
        func search(board: ChessBoard, nodeBudget: Int, cancellation: CancellationToken) -> SearchResult {
            searches += 1
            if let stop = cancelAtSearch, stop.number == searches { stop.token.cancel() }
            return inner.search(board: board, nodeBudget: nodeBudget, cancellation: cancellation)
        }
    }

    private static let first: StockfishEngine? = StockfishEngine()
    private static let second: StockfishEngine? = StockfishEngine()
    private var directory: URL!
    private var database: SQLiteDatabase!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        try Schema.migrate(database)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine() throws -> StockfishEngine {
        guard let engine = Self.first else { throw XCTSkip("Stockfish unavailable") }
        return engine
    }

    /// 3...Nf6?? allows Qxf7#, and 4.d3?? misses it.
    private let opening = "[Event \"t\"]\n\n1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. d3 Nxh5"
    /// The same first moves, then a different game.
    private let sameStart = "[Event \"t\"]\n\n1. e4 e5 2. Bc4 Nc6 3. Nf3 Nf6 4. d3 Be7"

    private func makeGame(_ pgn: String, key: String) -> GameRecord {
        let parsed = PGNParser.parse(pgn)
        return GameRecord(gameKey: key, url: "https://example.com/\(key)", uuid: key, pgn: pgn,
                          startFEN: parsed.startFEN,
                          moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                          endTime: Date(), timeClass: .rapid, timeControl: "600", rules: "chess", rated: true,
                          white: GameSide(username: "white", rating: 1500, resultCode: "win"),
                          black: GameSide(username: "black", rating: 1500, resultCode: "resigned"),
                          eco: nil, ecoURL: nil, openingName: nil, parseState: .parsed, plyCount: parsed.moves.count)
    }

    private func emptyBundle() -> BundledOpeningEvaluations {
        BundledOpeningEvaluations(url: directory.appendingPathComponent("missing.tsv"))
    }

    func testAReviewFromTheCacheIsTheReviewWithoutIt() throws {
        let stockfish = try engine()
        let cache = PositionCache(repository: PositionCacheRepository(database: database), bundled: emptyBundle())
        let game = makeGame(opening, key: "a")

        let plain = try GameAnalyzer(engine: stockfish).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                cancellation: CancellationToken())
        _ = try GameAnalyzer(engine: stockfish, cache: cache).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                      cancellation: CancellationToken())
        let counting = CountingEngine(stockfish)
        let cached = try GameAnalyzer(engine: counting, cache: cache).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                              cancellation: CancellationToken())
        XCTAssertEqual(counting.searches, 0, "every position of a short game is in the cache the second time")
        XCTAssertEqual(cached.moves, plain.moves, "every stored field")
        XCTAssertEqual(cached.whiteAccuracy, plain.whiteAccuracy)

        let other = CountingEngine(stockfish)
        _ = try GameAnalyzer(engine: other, cache: cache).analyze(game: makeGame(sameStart, key: "b"), deep: true,
                                                                  reviewDepth: .quick, cancellation: CancellationToken())
        XCTAssertEqual(other.searches, 4, "a game that opens the same way searches only its own positions")

        let deeper = CountingEngine(stockfish)
        _ = try GameAnalyzer(engine: deeper, cache: cache).analyze(game: game, deep: true, reviewDepth: .standard,
                                                                   cancellation: CancellationToken())
        XCTAssertEqual(deeper.searches, 9, "another level is another search")
    }

    func testAReviewStoppedPartWayCarriesOnWhereItStopped() throws {
        let stockfish = try engine()
        let cache = PositionCache(repository: nil, bundled: emptyBundle())
        // A game that does not start from the standard position: only this session's memory helps.
        let pgn = "[Event \"t\"]\n[SetUp \"1\"]\n[FEN \"r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3\"]\n\n3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7"
        let game = makeGame(pgn, key: "stopped")
        let plain = try GameAnalyzer(engine: stockfish).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                cancellation: CancellationToken())

        let first = CountingEngine(stockfish)
        let token = CancellationToken()
        first.cancelAtSearch = (6, token)
        XCTAssertThrowsError(try GameAnalyzer(engine: first, cache: cache).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                                   cancellation: token))
        let second = CountingEngine(stockfish)
        let resumed = try GameAnalyzer(engine: second, cache: cache).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                             cancellation: CancellationToken())
        XCTAssertEqual(second.searches, game.plyCount + 1 - 5, "the five searches finished before the stop are not made again")
        XCTAssertEqual(resumed.moves, plain.moves, "and the review is the one it would have been")
    }

    func testTheBundleIsUsedOnlyForTheEngineItWasMadeWith() throws {
        let stockfish = try engine()
        let signature = PositionCache.signature(of: stockfish)
        let url = directory.appendingPathComponent("bundle.tsv")
        try "#engine\t\(signature)\n500000\te2e4\tcp:-30\te7e5\te7e5 g1f3\t19\t500321\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let bundle = BundledOpeningEvaluations(url: url)

        let hit = bundle.evaluations(engine: signature, nodes: 500_000, keys: ["e2e4", "d2d4"])
        XCTAssertEqual(hit["e2e4"], CachedEvaluation(score: .centipawns(-30), bestMoveUCI: "e7e5",
                                                     lineUCI: ["e7e5", "g1f3"], depth: 19, nodes: 500_321))
        XCTAssertNil(hit["d2d4"])
        XCTAssertTrue(bundle.evaluations(engine: "other", nodes: 500_000, keys: ["e2e4"]).isEmpty)
        XCTAssertTrue(bundle.evaluations(engine: signature, nodes: 1_500_000, keys: ["e2e4"]).isEmpty)
    }

    func testPartialResultsAddUpToTheFinishedReview() throws {
        let stockfish = try engine()
        guard let second = Self.second else { throw XCTSkip("Stockfish unavailable") }
        var partials: [[MoveAnalysis]] = []
        let game = makeGame(opening, key: "c")
        let review = try GameAnalyzer(engine: stockfish, slowHelpers: [second])
            .analyze(game: game, deep: true, reviewDepth: .quick, cancellation: CancellationToken(),
                     onPartial: { partials.append($0) })
        let alone = try GameAnalyzer(engine: stockfish).analyze(game: game, deep: true, reviewDepth: .quick,
                                                                cancellation: CancellationToken())

        XCTAssertEqual(review.moves, alone.moves, "a slower helper never changes the result")
        XCTAssertEqual(partials.last, review.moves, "the last partial review is the finished one")
        XCTAssertEqual(partials.map(\.count), partials.map(\.count).sorted(), "moves are only ever added")
        for partial in partials {
            XCTAssertEqual(partial.map(\.ply), partial.map(\.ply).sorted())
            for move in partial { XCTAssertEqual(move, review.moves[move.ply], "and never change once shown") }
        }
    }

    func testRemovingTheLastPlayerClearsTheCache() throws {
        let repository = PositionCacheRepository(database: database)
        let entry = CachedEvaluation(score: .centipawns(20), bestMoveUCI: "e2e4", lineUCI: ["e2e4"], depth: 19, nodes: 500_000)
        try repository.store(engine: "e", nodes: 500_000, entries: [("", entry)])
        XCTAssertEqual(try repository.evaluations(engine: "e", nodes: 500_000, keys: [""]), ["": entry])

        let players = PlayerRepository(database: database)
        try players.delete(id: UUID())
        XCTAssertTrue(try repository.evaluations(engine: "e", nodes: 500_000, keys: [""]).isEmpty)
    }
}

/// The bundled openings must be what this device's engine would search; checked on a sample, at
/// the levels the file has.
final class BundledOpeningsTests: XCTestCase {
    func testBundledOpeningsMatchALiveSearch() throws {
        guard let engine = StockfishEngine() else { throw XCTSkip("Stockfish unavailable") }
        let signature = PositionCache.signature(of: engine)
        let bundle = BundledOpeningEvaluations.shared
        let sample = ["", "e2e4", "e2e4 c7c5", "d2d4 g8f6 c2c4 e7e6", "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6"]
        var checked = 0
        for level in ReviewDepth.allCases where level.nodesPerPosition <= 1_500_000 {
            let found = bundle.evaluations(engine: signature, nodes: level.nodesPerPosition, keys: sample)
            for key in sample {
                guard let cached = found[key] else { continue }
                let board = try XCTUnwrap(ChessBoard(fen: ChessBoard.startFEN))
                for uci in key.split(separator: " ") { board.makeMove(try XCTUnwrap(Move.fromUCI(uci))) }
                let live = try GameAnalyzer(engine: engine).search(board, nodes: level.nodesPerPosition)
                XCTAssertEqual(CachedEvaluation(live), cached, "\(level.rawValue): \(key.isEmpty ? "start" : key)")
                checked += 1
            }
        }
        if checked == 0 { throw XCTSkip("no bundled openings for this engine") }
    }
}
