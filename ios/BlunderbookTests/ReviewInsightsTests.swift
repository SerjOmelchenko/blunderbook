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

/// What the game screen works out on screen: clocks from the PGN, material, turning points, the
/// squares a pattern is about, theory where the game left the book, and the player's history.
final class ReviewInsightsTests: XCTestCase {

    // MARK: Clock

    func testClockCommentsAreReadForEachMove() {
        let chessCom = PGNParser.parse("""
            [TimeControl "600"]

            1. e4 {[%clk 0:09:58.5]} 1... e5 {[%clk 0:09:59]} 2. Nf3 {[%clk 0:09:41]} 2... Nc6 1-0
            """)
        XCTAssertEqual(chessCom.clocks, [598.5, 599, 581, nil])
        let lichess = PGNParser.parse("1. d4 { [%clk 0:03:00] } 1... d5 { [%eval 0.2] [%clk 0:02:58] } *")
        XCTAssertEqual(lichess.clocks, [180, 178])
        let variation = PGNParser.parse("1. e4 {[%clk 0:01:00]} (1. d4 {[%clk 0:00:01]}) 1... e5 *")
        XCTAssertEqual(variation.clocks, [60, nil], "a variation's clock is not the game's")
    }

    func testTimeSpentCountsTheIncrementAndFindsTheScramble() throws {
        let clock = try XCTUnwrap(GameClock(clocks: [598, 599, 540, 590, 50, 585], timeControl: "600+2"))
        XCTAssertEqual(clock.spent, [4, 3, 60, 11, 492, 7])
        XCTAssertEqual(clock.lowTime, 60)
        XCTAssertEqual(clock.lowTimeStart(for: .white), 4)
        XCTAssertNil(clock.lowTimeStart(for: .black))
        XCTAssertEqual(clock.clocks(afterPlies: 3).white, 540)
        XCTAssertEqual(clock.clocks(afterPlies: 3).black, 599)
        XCTAssertEqual(GameClock(clocks: [170], timeControl: "180")?.lowTime, 18, "a tenth of a short game")
    }

    func testDailyGamesAndBareGamesHaveNoClock() {
        XCTAssertNil(GameClock(clocks: [86_000], timeControl: "1/86400"))
        XCTAssertNil(GameClock(clocks: [nil, nil], timeControl: "600"))
    }

    func testClockFormats() {
        XCTAssertEqual(GameClock.format(118), "1:58")
        XCTAssertEqual(GameClock.format(7.9), "0:07")
        XCTAssertEqual(GameClock.format(3723), "1:02:03")
        XCTAssertEqual(GameClock.formatSpent(4), "4s")
        XCTAssertEqual(GameClock.formatSpent(118), "1:58")
    }

    // MARK: Material

    func testMaterialShowsOnlyWhatOneSideHasMore() throws {
        // White: queen, rook, knight, three pawns. Black: queen, rook, four pawns.
        let pieces = try XCTUnwrap(ChessBoard(fen: "3qr1k1/p4ppp/8/8/8/2N5/5PPP/3QR1K1 w - - 0 1")).snapshot
        let balance = MaterialBalance(pieces: pieces)
        XCTAssertEqual(balance.ahead[.white], [.knight])
        XCTAssertEqual(balance.ahead[.black], [.pawn])
        XCTAssertEqual(balance.difference, 2)
        XCTAssertEqual(balance.lead(for: .white), 2)
        XCTAssertEqual(balance.lead(for: .black), 0)
    }

    // MARK: Turning points

    private func move(_ ply: Int, loss: Double, severity: Severity?, phase: GamePhase = .middlegame) -> MoveAnalysis {
        MoveAnalysis(ply: ply, mover: ply % 2 == 0 ? .white : .black, san: "a3", uci: "a2a3",
                     fenBefore: ChessBoard.startFEN, scoreBefore: .centipawns(0), scoreAfter: .centipawns(0),
                     lineSAN: [], lineUCI: [], depth: 20, nodes: 1,
                     labels: MoveLabels(bestMoveSAN: nil, bestLineSAN: [], bestLineUCI: [], confirmed: false,
                                        loss: loss, accuracy: Scoring.moveAccuracy(loss: loss), severity: severity,
                                        phase: phase, tags: [], consequence: .evaluationLoss, explanation: "",
                                        isBest: loss == 0))
    }

    func testAnOpponentErrorIsMissedOrPunishedByTheReply() {
        let moves = [
            move(0, loss: 0, severity: nil, phase: .opening),
            move(1, loss: 30, severity: .blunder),      // their blunder
            move(2, loss: 28, severity: .blunder),      // missed it
            move(3, loss: 12, severity: .mistake),      // their mistake
            move(4, loss: 0.5, severity: nil),          // took it
            move(5, loss: 6, severity: .inaccuracy),    // too small to call a chance
            move(6, loss: 0, severity: nil, phase: .endgame),
        ]
        let insights = ReviewInsights(moves: moves, player: .white) { $0.severity }
        XCTAssertEqual(insights.moments, [2: .missedChance, 4: .punished])
        XCTAssertEqual(insights.keyMoments, [2, 4])
        XCTAssertEqual(insights.biggestError, 2)
        XCTAssertEqual(insights.errorCounts[.white]?[.blunder], 1)
        XCTAssertEqual(insights.errorCounts[.black]?[.blunder], 1)
        XCTAssertEqual(insights.errorCounts[.black]?[.inaccuracy], 1)
        XCTAssertEqual(insights.phaseStarts, [.opening: 0, .middlegame: 1, .endgame: 6])
        XCTAssertEqual(insights.phaseAccuracy[.opening]?.white, 100)
        XCTAssertNil(insights.phaseAccuracy[.opening]?.black, "Black made no opening move here")
    }

    func testTheBlackPlayersChancesComeFromWhitesErrors() {
        let moves = [move(0, loss: 25, severity: .blunder), move(1, loss: 0, severity: nil)]
        let insights = ReviewInsights(moves: moves, player: .black) { $0.severity }
        XCTAssertEqual(insights.moments, [1: .punished])
        XCTAssertEqual(insights.keyMoments, [1])
    }

    // MARK: Targets

    func testAnAllowedForkRingsThePiecesItHits() throws {
        let before = try XCTUnwrap(ChessBoard(fen: "4k3/8/8/8/1n6/8/7P/R3K3 w - - 0 1"))
        let played = try XCTUnwrap(Move.fromUCI("h2h3"))
        let after = before.copy()
        after.makeMove(played)
        let context = DetectionContext(boardBefore: before, playedMove: played, boardAfter: after,
                                       bestMove: nil, bestLine: [],
                                       replyLine: ["b4c2", "e1d2", "c2a1"].compactMap(Move.fromUCI),
                                       mover: .white, scoreBefore: .centipawns(0), scoreAfter: .centipawns(-500),
                                       loss: 40, isBest: false)
        XCTAssertEqual(PatternDetectors.targetSquares(for: .allowedFork, in: context).sorted(),
                       [Square.parse("a1")!, Square.parse("e1")!])
    }

    func testAMissedCaptureRingsThePieceToTake() throws {
        let before = try XCTUnwrap(ChessBoard(fen: "4k3/8/8/3n4/8/8/8/3QK3 w - - 0 1"))
        let played = try XCTUnwrap(Move.fromUCI("e1e2"))
        let after = before.copy()
        after.makeMove(played)
        let context = DetectionContext(boardBefore: before, playedMove: played, boardAfter: after,
                                       bestMove: Move.fromUCI("d1d5"), bestLine: [Move.fromUCI("d1d5")!],
                                       replyLine: [], mover: .white, scoreBefore: .centipawns(300),
                                       scoreAfter: .centipawns(0), loss: 30, isBest: false)
        XCTAssertEqual(PatternDetectors.targetSquares(for: .missedCapture, in: context), [Square.parse("d5")!])
    }

    // MARK: Opening

    func testTheoryIsTheBooksMoveWhereTheGameLeftIt() throws {
        let book = OpeningBook(tsv: "eco\tname\tpgn\nC41\tPhilidor Defense\t1. e4 e5 2. Nf3 d6\n")
        let board = ChessBoard()
        for uci in ["e2e4", "e7e5"] { board.makeMove(try XCTUnwrap(Move.fromUCI(uci))) }
        XCTAssertEqual(book.theoryMoves(from: board).map(\.uci), ["g1f3"])
        board.makeMove(try XCTUnwrap(Move.fromUCI("b1c3")))
        XCTAssertTrue(book.theoryMoves(from: board).isEmpty)
    }
}

/// The player's history the review reads: their record in an opening and how often a pattern
/// came up before.
final class ReviewHistoryTests: XCTestCase {
    private var database: SQLiteDatabase!
    private var players: PlayerRepository!
    private var games: GameRepository!
    private var analyses: AnalysisRepository!
    private var statistics: StatisticsRepository!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: directory.appendingPathComponent("test.sqlite").path)
        try Schema.migrate(database)
        players = PlayerRepository(database: database)
        games = GameRepository(database: database)
        analyses = AnalysisRepository(database: database)
        statistics = StatisticsRepository(database: database)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func game(_ index: Int, daysAgo: Double, result: String, opening: String) -> GameRecord {
        let pgn = "1. e4 e5 2. Nf3 d6 *"
        let parsed = PGNParser.parse(pgn)
        return GameRecord(gameKey: "g\(index)", url: "https://example.com/\(index)", uuid: "g\(index)", pgn: pgn,
                          startFEN: parsed.startFEN,
                          moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                          endTime: Date().addingTimeInterval(-daysAgo * 86_400), timeClass: .rapid, timeControl: "600",
                          rules: "chess", rated: true,
                          white: GameSide(username: "alice", rating: 1500, resultCode: result),
                          black: GameSide(username: "bob", rating: 1500, resultCode: result == "win" ? "resigned" : "win"),
                          eco: "C41", ecoURL: nil, openingName: opening, parseState: .parsed,
                          plyCount: parsed.moves.count)
    }

    private func deepReview(_ game: GameRecord, forkAt plies: [Int]) -> GameAnalysis {
        var provenance = AnalysisPolicy.activeProvenance
        provenance.policyID = DeepReview.identifier
        var analysis = GameAnalysis(gameKey: game.gameKey, provenance: provenance, status: .complete, nextPly: 4)
        analysis.completedAt = Date()
        analysis.moves = (0..<4).map { ply in
            let isFork = plies.contains(ply)
            return MoveAnalysis(ply: ply, mover: ply % 2 == 0 ? .white : .black, san: "x", uci: "a2a3",
                                fenBefore: ChessBoard.startFEN, scoreBefore: .centipawns(0), scoreAfter: .centipawns(0),
                                lineSAN: [], lineUCI: [], depth: 1, nodes: 1,
                                labels: MoveLabels(bestMoveSAN: nil, bestLineSAN: [], bestLineUCI: [], confirmed: false,
                                                   loss: isFork ? 30 : 0, accuracy: isFork ? 10 : 100,
                                                   severity: isFork ? .blunder : nil, phase: .opening,
                                                   tags: isFork ? [.allowedFork] : [], consequence: .losesMaterial,
                                                   explanation: "", isBest: !isFork))
        }
        return analysis
    }

    func testTheOpeningRecordCountsEveryGameInThatOpening() throws {
        var player = TrackedPlayer(providerID: "1", username: "alice", displayUsername: "alice")
        player.hasVerifiedWindow = true
        try players.save(player)
        let played = [game(1, daysAgo: 3, result: "win", opening: "Philidor Defense"),
                      game(2, daysAgo: 2, result: "agreed", opening: "Philidor Defense"),
                      game(3, daysAgo: 1, result: "resigned", opening: "Philidor Defense"),
                      game(4, daysAgo: 1, result: "win", opening: "Scotch Game")]
        try games.upsert(played)
        for item in played { try games.link(playerID: player.id, game: item, color: .white) }
        let record = try statistics.openingRecord(playerID: player.id, openingName: "Philidor Defense")
        XCTAssertEqual(record, OpeningRecord(wins: 1, draws: 1, losses: 1))
        XCTAssertEqual(record.score, 50)
    }

    func testThePatternCountLooksThirtyDaysBackAndLeavesTheGameOut() throws {
        var player = TrackedPlayer(providerID: "1", username: "alice", displayUsername: "alice")
        player.hasVerifiedWindow = true
        try players.save(player)
        let old = game(1, daysAgo: 45, result: "win", opening: "x")
        let recent = game(2, daysAgo: 10, result: "win", opening: "x")
        let current = game(3, daysAgo: 1, result: "win", opening: "x")
        try games.upsert([old, recent, current])
        for item in [old, recent, current] { try games.link(playerID: player.id, game: item, color: .white) }
        try analyses.save(deepReview(old, forkAt: [0]))
        // The opponent's fork (ply 1) is not the player's error.
        try analyses.save(deepReview(recent, forkAt: [0, 1, 2]))
        try analyses.save(deepReview(current, forkAt: [0]))
        XCTAssertEqual(try statistics.patternCount(playerID: player.id, tag: .allowedFork, before: current.endTime), 2)
    }
}
