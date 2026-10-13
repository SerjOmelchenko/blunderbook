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

/// The single games Analytics offers to analyse: last loss, biggest upset, weakest opening, random.
final class GamePickTests: XCTestCase {

    private var database: SQLiteDatabase!
    private var players: PlayerRepository!
    private var games: GameRepository!
    private var analyses: AnalysisRepository!
    private var picks: GamePickRepository!
    private var temporaryDirectory: URL!
    private var player: TrackedPlayer!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        try Schema.migrate(database)
        players = PlayerRepository(database: database)
        games = GameRepository(database: database)
        analyses = AnalysisRepository(database: database)
        picks = GamePickRepository(database: database)
        player = TrackedPlayer(providerID: "1", username: "alice", displayUsername: "alice")
        player.hasVerifiedWindow = true
        try players.save(player)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// One game for alice as White. `result` is her result code; the opponent's rating is
    /// `opponent`, hers 1500.
    @discardableResult
    private func addGame(_ index: Int, result: String, opponent: Int = 1500, daysAgo: Double,
                         opening: String = "Scotch Game", timeClass: TimeClass = .rapid) throws -> GameRecord {
        let pgn = "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0"
        let parsed = PGNParser.parse(pgn)
        let opponentResult = result == "win" ? "checkmated" : (ResultCodes.outcome(for: result) == .draw ? result : "win")
        let game = GameRecord(gameKey: "game-\(index)", url: "https://example.com/\(index)", uuid: "game-\(index)",
                              pgn: pgn, startFEN: parsed.startFEN,
                              moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                              endTime: Date().addingTimeInterval(-daysAgo * 86_400), timeClass: timeClass,
                              timeControl: "600", rules: "chess", rated: true,
                              white: GameSide(username: "alice", rating: 1500, resultCode: result),
                              black: GameSide(username: "bob\(index)", rating: opponent, resultCode: opponentResult),
                              eco: nil, ecoURL: nil, openingName: opening, parseState: .parsed,
                              plyCount: parsed.moves.count)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        return game
    }

    func testLastLossIsTheNewestLossOfTheTimeClass() throws {
        try addGame(1, result: "win", daysAgo: 1)
        try addGame(2, result: "timeout", daysAgo: 2)
        try addGame(3, result: "resigned", daysAgo: 5)
        try addGame(4, result: "checkmated", daysAgo: 0.5, timeClass: .blitz)
        XCTAssertEqual(try picks.lastLoss(playerID: player.id, timeClass: .rapid), "game-2")
        XCTAssertEqual(try picks.lastLoss(playerID: player.id, timeClass: .blitz), "game-4")
        XCTAssertNil(try picks.lastLoss(playerID: player.id, timeClass: .daily))
    }

    func testBiggestUpsetIsTheLossToTheLowestRatedOpponentInTheWindow() throws {
        try addGame(1, result: "resigned", opponent: 1450, daysAgo: 3)
        try addGame(2, result: "resigned", opponent: 1280, daysAgo: 10)
        try addGame(3, result: "resigned", opponent: 1100, daysAgo: 200) // too long ago
        try addGame(4, result: "win", opponent: 1000, daysAgo: 1)       // not a loss
        try addGame(5, result: "resigned", opponent: 1700, daysAgo: 1)  // rated above: no upset
        let since = Date().addingTimeInterval(-90 * 86_400)
        let upset = try picks.biggestUpset(playerID: player.id, timeClass: .rapid, since: since)
        XCTAssertEqual(upset, GamePickRepository.Upset(gameKey: "game-2", gap: 220))
    }

    func testWeakestOpeningGroupsByFamilyAndNeedsEnoughGames() throws {
        // Sicilian, across two variations: 1 win, 1 draw, 3 losses = 30 %.
        try addGame(1, result: "win", daysAgo: 9, opening: "Sicilian Defense: Najdorf Variation")
        try addGame(2, result: "agreed", daysAgo: 8, opening: "Sicilian Defense: Dragon Variation")
        try addGame(3, result: "resigned", daysAgo: 7, opening: "Sicilian Defense")
        try addGame(4, result: "resigned", daysAgo: 6, opening: "Sicilian Defense: Najdorf Variation")
        try addGame(5, result: "timeout", daysAgo: 2, opening: "Sicilian Defense: Alapin Variation")
        // Scotch: 0 % but only two games, too few to count.
        try addGame(6, result: "resigned", daysAgo: 1)
        try addGame(7, result: "resigned", daysAgo: 1.5)
        let weak = try XCTUnwrap(try picks.weakestOpening(playerID: player.id, timeClass: .rapid))
        XCTAssertEqual(weak.name, "Sicilian Defense")
        XCTAssertEqual(weak.games, 5)
        XCTAssertEqual(weak.score, 0.3, accuracy: 0.0001)
        XCTAssertEqual(weak.gameKey, "game-5", "its latest game")
    }

    func testRandomPrefersGamesWithoutAnInDepthReview() throws {
        try addGame(1, result: "win", daysAgo: 1)
        try addGame(2, result: "resigned", daysAgo: 2)
        var provenance = AnalysisPolicy.activeProvenance
        provenance.policyID = DeepReview.identifier
        var analysis = GameAnalysis(gameKey: "game-1", provenance: provenance, status: .complete, nextPly: 0)
        analysis.completedAt = Date()
        try analyses.save(analysis)
        for _ in 0..<20 {
            XCTAssertEqual(try picks.random(playerID: player.id, timeClass: .rapid), "game-2")
        }
        try addGame(3, result: "win", daysAgo: 3, timeClass: .blitz)
        XCTAssertEqual(try picks.random(playerID: player.id, timeClass: .blitz), "game-3")
        XCTAssertNil(try picks.random(playerID: player.id, timeClass: .daily))
    }
}
