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

final class PersistenceTests: XCTestCase {

    private var database: SQLiteDatabase!
    private var players: PlayerRepository!
    private var games: GameRepository!
    private var analyses: AnalysisRepository!
    private var statistics: StatisticsRepository!
    private var queue: QueueRepository!
    private var backup: BackupService!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        database = try SQLiteDatabase(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        try Schema.migrate(database)
        players = PlayerRepository(database: database)
        games = GameRepository(database: database)
        analyses = AnalysisRepository(database: database)
        statistics = StatisticsRepository(database: database)
        queue = QueueRepository(database: database)
        backup = BackupService(database: database, players: players, games: games, analyses: analyses)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: Helpers

    private func makePlayer(_ name: String, providerID: String?) throws -> TrackedPlayer {
        var player = TrackedPlayer(providerID: providerID, username: name, displayUsername: name)
        player.hasVerifiedWindow = true
        try players.save(player)
        return player
    }

    private func makeGame(index: Int, white: String, black: String, daysAgo: Double,
                          timeClass: TimeClass = .rapid, whiteResult: String = "win") -> GameRecord {
        let pgn = "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6 1-0"
        let parsed = PGNParser.parse(pgn)
        return GameRecord(gameKey: "game-\(index)",
                          url: "https://example.com/\(index)",
                          uuid: "game-\(index)",
                          pgn: pgn,
                          startFEN: parsed.startFEN,
                          moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                          endTime: Date().addingTimeInterval(-daysAgo * 86_400),
                          timeClass: timeClass,
                          timeControl: "600",
                          rules: "chess",
                          rated: true,
                          white: GameSide(username: white, rating: 1400 + index, resultCode: whiteResult),
                          black: GameSide(username: black, rating: 1400, resultCode: whiteResult == "win" ? "checkmated" : "win"),
                          eco: "C44", ecoURL: nil, openingName: "Scotch Game",
                          parseState: .parsed,
                          plyCount: parsed.moves.count)
    }

    // MARK: Tests

    func testSchemaMigratesOnce() throws {
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)
        try Schema.migrate(database)
        XCTAssertEqual(try database.userVersion(), Schema.currentVersion)
    }

    func testRepeatedImportsNeverDuplicateAGame() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        for _ in 0..<3 {
            try games.upsert([game])
            try games.link(playerID: player.id, game: game, color: .white)
        }
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 1)
    }

    func testTheRatingChartCoversTheWholeRangeNotJustRecentGames() throws {
        // 600 days with one rated game each: more than the old 400-game cap, so the bug made
        // "Last year" and "All time" draw the same recent games.
        let player = try makePlayer("alice", providerID: "1")
        let records = (0..<600).map {
            makeGame(index: $0, white: "alice", black: "bob", daysAgo: Double($0) + 0.5)
        }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }

        var lastYear = GameFilters.default
        lastYear.dateRange = .lastYear
        var allTime = GameFilters.default
        allTime.dateRange = .allTime

        let year = try statistics.ratingSeries(playerID: player.id, filters: lastYear, scope: .allDownloaded)
        let all = try statistics.ratingSeries(playerID: player.id, filters: allTime, scope: .allDownloaded)
        XCTAssertEqual(all.reduce(0) { $0 + $1.games }, 600, "every game counts")
        XCTAssertLessThan(year.reduce(0) { $0 + $1.games }, 600)
        XCTAssertLessThan(all.first!.date, year.first!.date, "all time reaches further back")
        XCTAssertEqual(all.last!.date, year.last!.date, "both end at the latest game")
    }

    func testReviewStorageStartsAtZeroAndGrowsWithReviews() throws {
        XCTAssertEqual(try analyses.storageBytes(), 0)

        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        var analysis = GameAnalysis(gameKey: game.gameKey,
                                    provenance: AnalysisPolicy.activeProvenance,
                                    status: .complete, nextPly: 0)
        analysis.completedAt = Date()
        try analyses.save(analysis)
        XCTAssertGreaterThan(try analyses.storageBytes(), 0)
    }

    func testChangedMoveContentInvalidatesTheStoredAnalysis() throws {
        let player = try makePlayer("alice", providerID: "1")
        var game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        var analysis = GameAnalysis(gameKey: game.gameKey,
                                    provenance: AnalysisPolicy.activeProvenance,
                                    status: .complete, nextPly: 0)
        analysis.completedAt = Date()
        try analyses.save(analysis)
        XCTAssertNotNil(try analyses.header(gameKey: game.gameKey))

        game.moveHash = "a-different-hash"
        try games.upsert([game])
        XCTAssertNil(try analyses.header(gameKey: game.gameKey),
                     "a changed move sequence must invalidate the saved review")
    }

    func testFreeWindowTakesTheNewestThousandAcrossAllClasses() throws {
        let player = try makePlayer("alice", providerID: "1")
        var records: [GameRecord] = []
        let classes: [TimeClass] = [.bullet, .blitz, .rapid, .daily]
        for index in 0..<1_001 {
            records.append(makeGame(index: index, white: "alice", black: "bob",
                                    daysAgo: Double(index), timeClass: classes[index % 4]))
        }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }

        let inWindow = try games.publishFreeWindow(playerID: player.id, limit: 1_000)
        XCTAssertEqual(inWindow, 1_000)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 1_001)

        // The oldest game is the one that falls out.
        let oldest = try games.entry(playerID: player.id, gameKey: "game-1000")
        XCTAssertEqual(oldest?.inFreeWindow, false)
        let newest = try games.entry(playerID: player.id, gameKey: "game-0")
        XCTAssertEqual(newest?.inFreeWindow, true)
    }

    func testBulkCandidatesCanBeLimitedToOneTimeClass() throws {
        let player = try makePlayer("alice", providerID: "1")
        let classes: [TimeClass] = [.bullet, .blitz, .rapid, .daily]
        let records = (0..<8).map {
            makeGame(index: $0, white: "alice", black: "bob", daysAgo: Double($0), timeClass: classes[$0 % 4])
        }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }

        let rapid = try games.eligibleKeys(playerID: player.id, scope: .allDownloaded, timeClass: .rapid)
        XCTAssertEqual(rapid, ["game-2", "game-6"], "only rapid games, newest first")
        XCTAssertEqual(try games.eligibleKeys(playerID: player.id, scope: .allDownloaded).count, 8)
    }

    func testGamesListShowsTheWholeHistoryPageByPage() throws {
        let player = try makePlayer("alice", providerID: "1")
        let records = (0..<130).map { makeGame(index: $0, white: "alice", black: "bob", daysAgo: Double($0) * 5) }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }
        for record in records.prefix(3) {
            var analysis = GameAnalysis(gameKey: record.gameKey, provenance: AnalysisPolicy.activeProvenance,
                                        status: .complete, nextPly: 0)
            analysis.completedAt = Date()
            try analyses.save(analysis)
        }

        var analytics = GameFilters.default
        analytics.dateRange = .lastWeek
        let filters = analytics.ignoringDates
        XCTAssertEqual(try games.pageCount(playerID: player.id, filters: filters, scope: .allDownloaded), 130,
                       "the week chosen on Analytics does not narrow the list")
        XCTAssertEqual(try games.pageCount(playerID: player.id, filters: analytics, scope: .allDownloaded), 2)
        XCTAssertEqual(try games.pageCount(playerID: player.id, filters: filters, scope: .allDownloaded,
                                           status: .notReviewed), 127)
        XCTAssertEqual(try games.pageCount(playerID: player.id, filters: filters, scope: .allDownloaded,
                                           savedReviewsOnly: true), 3)

        var listed: [String] = []
        while true {
            let page = try games.page(playerID: player.id, filters: filters, scope: .allDownloaded,
                                      limit: 50, offset: listed.count)
            listed += page.map(\.game.gameKey)
            if page.count < 50 { break }
        }
        XCTAssertEqual(listed, records.map(\.gameKey), "every game once, newest first")
        XCTAssertEqual(analytics.activeCountIgnoringDates, 0)
    }

    func testOutOfWindowReviewStaysReadableButLeavesTheMetrics() throws {
        let player = try makePlayer("alice", providerID: "1")
        var records: [GameRecord] = []
        for index in 0..<1_001 {
            records.append(makeGame(index: index, white: "alice", black: "bob", daysAgo: Double(index)))
        }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }
        _ = try games.publishFreeWindow(playerID: player.id, limit: 1_000)

        var analysis = GameAnalysis(gameKey: "game-1000",
                                    provenance: AnalysisPolicy.activeProvenance,
                                    status: .complete, nextPly: 2)
        analysis.completedAt = Date()
        analysis.moves = [MoveAnalysis(ply: 0, mover: .white, san: "e4", uci: "e2e4",
                                       fenBefore: ChessBoard.startFEN,
                                       scoreBefore: .centipawns(20), scoreAfter: .centipawns(-400),
                                       lineSAN: [], lineUCI: [], depth: 8, nodes: 1000)]
        try analyses.save(analysis)

        // Readable regardless of scope.
        XCTAssertNotNil(try analyses.analysis(gameKey: "game-1000"))

        // The fixture spans about three years, so the date filter has to be opened up: this test
        // is about window membership, not about dates.
        var filters = GameFilters.default
        filters.dateRange = .allTime

        let coverage = try statistics.coverage(playerID: player.id, filters: filters, scope: .freeWindow)
        XCTAssertEqual(coverage.analysedGames, 0, "an out-of-window review must not enter free metrics")

        let premium = try statistics.coverage(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(premium.analysedGames, 1)
    }

    func testTheDefaultDateRangeNarrowsToTheLastYear() throws {
        let player = try makePlayer("alice", providerID: "1")
        let recent = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 10)
        let old = makeGame(index: 2, white: "alice", black: "bob", daysAgo: 800)
        try games.upsert([recent, old])
        try games.link(playerID: player.id, game: recent, color: .white)
        try games.link(playerID: player.id, game: old, color: .white)
        _ = try games.publishFreeWindow(playerID: player.id, limit: 1_000)

        XCTAssertEqual(GameFilters.default.dateRange, .lastYear, "last year is the default")
        XCTAssertEqual(try games.gameCount(playerID: player.id, filters: .default, scope: .freeWindow), 1)

        var allTime = GameFilters.default
        allTime.dateRange = .allTime
        XCTAssertEqual(try games.gameCount(playerID: player.id, filters: allTime, scope: .freeWindow), 2)

        var week = GameFilters.default
        week.dateRange = .lastWeek
        XCTAssertEqual(try games.gameCount(playerID: player.id, filters: week, scope: .freeWindow), 0)
    }

    func testSharedGamesAreStoredOnceWithPerPlayerColours() throws {
        let alice = try makePlayer("alice", providerID: "1")
        let bob = try makePlayer("bob", providerID: "2")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: alice.id, game: game, color: .white)
        try games.link(playerID: bob.id, game: game, color: .black)

        XCTAssertEqual(try database.queryOne("SELECT COUNT(*) AS value FROM games;")?.int("value"), 1)
        XCTAssertEqual(try games.entry(playerID: alice.id, gameKey: game.gameKey)?.outcome, .win)
        XCTAssertEqual(try games.entry(playerID: bob.id, gameKey: game.gameKey)?.outcome, .loss)
    }

    func testRemovingOnePlayerProtectsAnotherPlayersSharedGame() throws {
        let alice = try makePlayer("alice", providerID: "1")
        let bob = try makePlayer("bob", providerID: "2")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: alice.id, game: game, color: .white)
        try games.link(playerID: bob.id, game: game, color: .black)

        try players.delete(id: alice.id)
        XCTAssertNotNil(try games.game(key: game.gameKey), "bob still references this game")
        try players.delete(id: bob.id)
        XCTAssertNil(try games.game(key: game.gameKey), "nothing references it now")
    }

    func testUnknownOutcomesStayInTotalsButLeavePercentages() throws {
        let player = try makePlayer("alice", providerID: "1")
        let normal = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        let strange = makeGame(index: 2, white: "alice", black: "bob", daysAgo: 2, whiteResult: "somethingnew")
        try games.upsert([normal, strange])
        try games.link(playerID: player.id, game: normal, color: .white)
        try games.link(playerID: player.id, game: strange, color: .white)
        _ = try games.publishFreeWindow(playerID: player.id, limit: 1_000)

        let outcomes = try statistics.outcomes(playerID: player.id, filters: .default, scope: .freeWindow)
        XCTAssertEqual(outcomes.total, 2)
        XCTAssertEqual(outcomes.unknown, 1)
        XCTAssertEqual(outcomes.decided, 1)
        XCTAssertEqual(outcomes.percentage(outcomes.win), 100, accuracy: 0.001)
    }

    func testQueueDeduplicatesAndPrioritisesManualWork() throws {
        let player = try makePlayer("alice", providerID: "1")
        let records = (0..<3).map { makeGame(index: $0, white: "alice", black: "bob", daysAgo: Double($0)) }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }

        let entries = records.map { (gameKey: $0.gameKey, bucket: AllowanceBucket.window) }
        try queue.createBatch(playerID: player.id, label: "bulk", entries: entries)
        try queue.createBatch(playerID: player.id, label: "bulk again", entries: entries)
        XCTAssertEqual(try queue.counts().pending, 3, "duplicate jobs are ignored")

        _ = try queue.enqueueManual(playerID: player.id, gameKey: "game-2", bucket: .daily)
        let next = try queue.claimNextPendingItem(manual: true, bulk: true)
        XCTAssertEqual(next?.gameKey, "game-2", "a manual review runs before queued bulk work")
        XCTAssertEqual(next?.state, .running)

        XCTAssertNil(try queue.claimNextPendingItem(manual: true, bulk: false),
                     "the review is taken, and an engine without bulk work waits")
        XCTAssertNotNil(try queue.claimNextPendingItem(manual: false, bulk: true))
    }

    func testEfficiencyEnginesNeverTakeAReview() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        _ = try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .none)
        XCTAssertNil(try queue.claimNextPendingItem(manual: false, bulk: true))
        XCTAssertEqual(try queue.claimNextPendingItem(manual: true, bulk: false)?.gameKey, game.gameKey)
    }

    func testEnginesClaimingAtOnceNeverTakeTheSameGame() throws {
        let player = try makePlayer("alice", providerID: "1")
        let records = (0..<40).map { makeGame(index: $0, white: "alice", black: "bob", daysAgo: Double($0)) }
        try games.upsert(records)
        for record in records { try games.link(playerID: player.id, game: record, color: .white) }
        try queue.createBatch(playerID: player.id, label: "bulk",
                              entries: records.map { (gameKey: $0.gameKey, bucket: AllowanceBucket.none) })

        let lock = NSLock()
        var claimed: [String] = []
        let queue = self.queue!
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            while let item = try? queue.claimNextPendingItem(manual: false, bulk: true) {
                lock.lock()
                claimed.append(item.gameKey)
                lock.unlock()
            }
        }
        XCTAssertEqual(claimed.count, 40)
        XCTAssertEqual(Set(claimed).count, 40, "no game was handed to two engines")
        XCTAssertEqual(try queue.counts().running, 40)
    }

    func testQueuedWorkMovesToTheCurrentPolicy() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        let id = try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .none)
        try database.run("UPDATE queue_items SET policy_id = 'standard-v1', checkpoint_ply = 30 WHERE id = ?;",
                         [id.sqlValue])

        try queue.adoptCurrentPolicy()
        let item = try queue.item(id: id)
        XCTAssertEqual(item?.policyID, AnalysisPolicy.identifier)
        XCTAssertEqual(item?.checkpointPly, 0, "a game is never resumed half way")
    }

    func testInterruptedItemsReturnToPendingWithTheirCheckpoint() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        let id = try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .window)

        try queue.setState(.running, id: id, checkpointPly: 12)
        try queue.recoverInterruptedItems()
        let item = try queue.item(id: id)
        XCTAssertEqual(item?.state, QueueItemState.pending)
        XCTAssertEqual(item?.checkpointPly, 12)
        XCTAssertEqual(item?.chargedBucket, AllowanceBucket.window,
                       "the charged pot survives an interruption so a refund stays correct")
        XCTAssertEqual(item?.playerID, player.id)
    }

    func testBackupRoundTripKeepsGamesAndReviews() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        var analysis = GameAnalysis(gameKey: game.gameKey,
                                    provenance: AnalysisPolicy.activeProvenance,
                                    status: .complete, nextPly: 1)
        analysis.completedAt = Date()
        analysis.moves = [MoveAnalysis(ply: 0, mover: .white, san: "e4", uci: "e2e4",
                                       fenBefore: ChessBoard.startFEN,
                                       scoreBefore: .centipawns(20), scoreAfter: .centipawns(5),
                                       lineSAN: ["e5", "Nf3"], lineUCI: ["e7e5", "g1f3"], depth: 9, nodes: 1234)]
        try analyses.save(analysis)

        let url = try backup.export(to: temporaryDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Import into a fresh database.
        let otherPath = temporaryDirectory.appendingPathComponent("other.sqlite").path
        let other = try SQLiteDatabase(path: otherPath)
        try Schema.migrate(other)
        let otherPlayers = PlayerRepository(database: other)
        let otherGames = GameRepository(database: other)
        let otherAnalyses = AnalysisRepository(database: other)
        let otherBackup = BackupService(database: other, players: otherPlayers, games: otherGames, analyses: otherAnalyses)

        let staged = try otherBackup.stage(url: url)
        let preview = try otherBackup.preview(staged)
        XCTAssertEqual(preview.newGames, 1)
        XCTAssertEqual(preview.newAnalyses, 1)

        let result = try otherBackup.commit(staged)
        XCTAssertEqual(result.gamesAdded, 1)
        XCTAssertEqual(result.analysesAdded, 1)

        let restored = try otherAnalyses.analysis(gameKey: game.gameKey)
        XCTAssertEqual(restored?.moves, analysis.moves, "evaluations and lines survive the round trip")
        XCTAssertEqual(restored?.provenance, AnalysisPolicy.activeProvenance)

        // An imported player has no locally verified window until a refresh succeeds.
        XCTAssertEqual(try otherPlayers.player(providerID: "1")?.hasVerifiedWindow, false)
    }

    func testImportKeepsAnExistingCompleteReviewOnConflict() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        var mine = GameAnalysis(gameKey: game.gameKey, provenance: AnalysisPolicy.activeProvenance,
                                status: .complete, nextPly: 0)
        mine.completedAt = Date()
        try analyses.save(mine)

        let url = try backup.export(to: temporaryDirectory)
        // Re-importing into the same database must not overwrite what is already complete.
        let staged = try backup.stage(url: url)
        let result = try backup.commit(staged)
        XCTAssertEqual(result.analysesKept, 1)
        XCTAssertEqual(result.gamesSkipped, 1)
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, mine.id)
    }

    func testAnOlderCompleteReviewCountsUntilANewOneReplacesIt() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        var older = AnalysisPolicy.activeProvenance
        older.policyID = "standard-v2"
        var old = GameAnalysis(gameKey: game.gameKey, provenance: older, status: .complete, nextPly: 0)
        old.completedAt = Date()
        try analyses.save(old)
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, old.id, "an older review is shown")
        XCTAssertEqual(try games.entry(playerID: player.id, gameKey: game.gameKey)?.hasReview, true)
        var filters = GameFilters.default
        filters.dateRange = .allTime
        XCTAssertEqual(try statistics.coverage(playerID: player.id, filters: filters, scope: .allDownloaded).analysedGames, 1)

        // A failed attempt under the current policy leaves the older review in place.
        try analyses.markFailed(gameKey: game.gameKey, message: "test")
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, old.id)

        var new = GameAnalysis(gameKey: game.gameKey, provenance: AnalysisPolicy.activeProvenance,
                               status: .complete, nextPly: 0)
        new.completedAt = Date()
        try analyses.save(new)
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, new.id)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) AS value FROM analyses WHERE game_key = ?;",
                                              [game.gameKey.sqlValue]), 1, "the new review replaces every earlier one")
    }

    func testMigratingKeepsEveryEvaluationAndDropsTheLabels() throws {
        let path = temporaryDirectory.appendingPathComponent("v4.sqlite").path
        let old = try SQLiteDatabase(path: path)
        try Schema.migrate(old, to: 4)
        try old.run("""
            INSERT INTO players (id, provider_id, username, display_username, created_at)
            VALUES ('P', '1', 'alice', 'alice', 0);
            """)
        try old.run("""
            INSERT INTO games (game_key, url, pgn, start_fen, move_hash, end_time, time_class, time_control, rules,
                               rated, white_username, white_result, black_username, black_result, parse_state, ply_count)
            VALUES ('G', 'u', '1. e4', 'f', 'h', 0, 'rapid', '600', 'chess', 1, 'alice', 'win', 'bob', 'resigned',
                    'parsed', 1);
            """)
        try old.run("""
            INSERT INTO analyses (id, game_key, policy_id, engine_version, evaluation_version, scoring_version,
                                  tagger_version, status, next_ply, white_accuracy, black_accuracy, created_at, completed_at)
            VALUES ('A', 'G', 'standard-v2', 'e', 'n', 's', 't', 'complete', 1, 91.5, 80, 0, 1);
            """)
        try old.run("""
            INSERT INTO move_analyses (analysis_id, ply, mover, san, uci, fen_before, score_before, score_after,
                                       best_move_san, best_line_san, best_line_uci, reply_line_san, reply_line_uci,
                                       depth, nodes, confirmed, loss, accuracy, severity, phase, consequence,
                                       explanation, is_best)
            VALUES ('A', 0, 0, 'e4', 'e2e4', 'f', 'cp:20', 'cp:15', 'd4', 'd4 d5', 'd2d4 d7d5', 'e5 Nf3', 'e7e5 g1f3',
                    14, 100000, 0, 1.2, 96, NULL, 'opening', 'evaluationLoss', 'Fine.', 0);
            """)
        try old.run("INSERT INTO move_tags (analysis_id, ply, mover, tag) VALUES ('A', 0, 0, 'hangingPiece');")

        try Schema.migrate(old, to: 5)
        let row = try XCTUnwrap(try old.queryOne("SELECT * FROM move_evaluations WHERE analysis_id = 'A';"))
        XCTAssertEqual(row.string("score_before"), "cp:20")
        XCTAssertEqual(row.string("score_after"), "cp:15")
        XCTAssertEqual(row.string("line_san"), "e5 Nf3", "the line after the move is the old reply line")
        XCTAssertEqual(row.int("depth"), 14)
        let columns = try old.query("PRAGMA table_info(analyses);").compactMap { $0.string("name") }
        XCTAssertFalse(columns.contains("white_accuracy"))
        for table in ["move_analyses", "move_tags", "analysis_summaries", "analysis_tag_summaries"] {
            XCTAssertNil(try old.queryOne("SELECT name FROM sqlite_master WHERE name = ?;", [table.sqlValue]), table)
        }

        // Version 6 adds room for deep reviews and leaves the converted review as it was.
        try Schema.migrate(old)
        let review = try XCTUnwrap(try old.queryOne("SELECT * FROM analyses WHERE id = 'A';"))
        XCTAssertEqual(review.string("policy_id"), "standard-v2")
        XCTAssertNil(review.double("white_accuracy"), "old accuracies are not brought back")
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) AS value FROM move_evaluations;"), 1)
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) AS value FROM move_labels;"), 0)
    }

    func testMigratingSwitchesWaitingBatchesToDeepReviews() throws {
        let path = temporaryDirectory.appendingPathComponent("v6.sqlite").path
        let old = try SQLiteDatabase(path: path)
        try Schema.migrate(old, to: 6)
        try old.run("""
            INSERT INTO players (id, provider_id, username, display_username, created_at)
            VALUES ('P', '1', 'alice', 'alice', 0);
            """)
        try old.run("""
            INSERT INTO queue_batches (id, player_id, created_at, cancelled, total_items, label)
            VALUES ('B', 'P', 0, 0, 4, 'bulk'), ('S', 'P', 0, 0, 1, 'Deep review');
            """)
        try old.run("""
            INSERT INTO queue_items (id, batch_id, game_key, policy_id, priority, state, checkpoint_ply, created_at)
            VALUES ('waiting', 'B', 'g1', 'eval-v1', 100, 'pending', 12, 0),
                   ('done', 'B', 'g2', 'eval-v1', 100, 'completed', 40, 0),
                   ('twice', 'B', 'g3', 'eval-v1', 100, 'pending', 0, 0),
                   ('opened', 'S', 'g3', 'deep-v1', 0, 'pending', 0, 0);
            """)
        try old.run("INSERT INTO timing_samples (recorded_at, plies, seconds) VALUES (0, 80, 4);")

        try Schema.migrate(old)
        let policies = Dictionary(uniqueKeysWithValues: try old.query("SELECT id, policy_id FROM queue_items;")
            .compactMap { row in row.string("id").map { ($0, row.string("policy_id") ?? "") } })
        XCTAssertEqual(policies["waiting"], DeepReview.identifier, "a waiting bulk game becomes a deep review")
        XCTAssertEqual(policies["done"], "eval-v1", "finished work is left alone")
        XCTAssertNil(policies["twice"], "a game already waiting for a deep review keeps that one job")
        XCTAssertEqual(policies["opened"], DeepReview.identifier)
        XCTAssertEqual(try old.scalarInt("SELECT checkpoint_ply AS value FROM queue_items WHERE id = 'waiting';"), 0)
        XCTAssertEqual(try old.scalarInt("SELECT COUNT(*) AS value FROM timing_samples;"), 0,
                       "the estimate measures deep reviews afresh")
    }

    // MARK: Deep reviews

    private func makeAnalysis(for game: GameRecord, deep: Bool) -> GameAnalysis {
        var provenance = AnalysisPolicy.activeProvenance
        if deep { provenance.policyID = DeepReview.identifier }
        var analysis = GameAnalysis(gameKey: game.gameKey, provenance: provenance, status: .complete, nextPly: 2,
                                    whiteAccuracy: deep ? 62.5 : nil, blackAccuracy: deep ? 98 : nil)
        analysis.completedAt = Date()
        func labels(_ severity: Severity?, tags: [PatternTag], phase: GamePhase) -> MoveLabels? {
            guard deep else { return nil }
            return MoveLabels(bestMoveSAN: severity == nil ? nil : "d4", bestLineSAN: ["d4", "d5"],
                              bestLineUCI: ["d2d4", "d7d5"], confirmed: severity != nil,
                              loss: severity == nil ? 0 : 25, accuracy: severity == nil ? 100 : 25,
                              severity: severity, phase: phase, tags: tags,
                              consequence: severity == nil ? .evaluationLoss : .losesMaterial,
                              explanation: severity == nil ? "" : "Loses a knight.", isBest: severity == nil)
        }
        analysis.moves = [
            MoveAnalysis(ply: 0, mover: .white, san: "e4", uci: "e2e4", fenBefore: ChessBoard.startFEN,
                         scoreBefore: .centipawns(20), scoreAfter: .centipawns(-300),
                         lineSAN: ["e5"], lineUCI: ["e7e5"], depth: 9, nodes: 1000,
                         labels: labels(.blunder, tags: [.undefendedPiece, .allowedFork], phase: .opening)),
            MoveAnalysis(ply: 1, mover: .black, san: "e5", uci: "e7e5", fenBefore: ChessBoard.startFEN,
                         scoreBefore: .centipawns(-300), scoreAfter: .centipawns(-300),
                         lineSAN: [], lineUCI: [], depth: 9, nodes: 1000,
                         labels: labels(nil, tags: [], phase: .opening))
        ]
        return analysis
    }

    func testDeepReviewRoundTripsItsLabelsAndAccuracy() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        let deep = makeAnalysis(for: game, deep: true)
        try analyses.save(deep)
        let stored = try XCTUnwrap(try analyses.analysis(gameKey: game.gameKey))
        XCTAssertTrue(stored.isDeep)
        XCTAssertEqual(stored.moves, deep.moves, "labels survive storage")
        XCTAssertEqual(stored.whiteAccuracy, 62.5)
        let entry = try XCTUnwrap(try games.entry(playerID: player.id, gameKey: game.gameKey))
        XCTAssertTrue(entry.hasDeepReview)
        XCTAssertEqual(entry.accuracy, 62.5, "the list shows the player's own accuracy")
    }

    func testOlderDeepReviewsAreRescoredFromTheirStoredLosses() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        var deep = makeAnalysis(for: game, deep: true)
        deep.provenance.scoringVersion = "winpct-2024"
        try analyses.save(deep)

        XCTAssertEqual(try analyses.rescoreDeepReviews(), 1)
        let stored = try XCTUnwrap(try analyses.analysis(gameKey: game.gameKey))
        XCTAssertEqual(stored.provenance.scoringVersion, DeepReview.scoringIdentifier)
        XCTAssertEqual(stored.moves.map(\.labels?.loss), deep.moves.map(\.labels?.loss), "losses stay as they were")
        XCTAssertEqual(try XCTUnwrap(stored.moves[0].labels?.accuracy), Scoring.moveAccuracy(loss: 25), accuracy: 0.0001)
        let expected = Scoring.gameAccuracies(stored.moves)
        XCTAssertEqual(try XCTUnwrap(stored.whiteAccuracy), try XCTUnwrap(expected.white), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(stored.blackAccuracy), try XCTUnwrap(expected.black), accuracy: 0.0001)
        XCTAssertEqual(try analyses.rescoreDeepReviews(), 0, "a current review is left alone")
    }

    func testADeepReviewReplacesAStandardOneButNeverTheReverse() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        try analyses.save(makeAnalysis(for: game, deep: false))
        let deep = makeAnalysis(for: game, deep: true)
        try analyses.save(deep)
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, deep.id)

        // A bulk game that was already queued finishes after the deep review.
        try analyses.save(makeAnalysis(for: game, deep: false))
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.id, deep.id, "the deep review stays")
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) AS value FROM analyses WHERE game_key = ?;",
                                              [game.gameKey.sqlValue]), 1)

        // A failed deep review of a game with a standard review leaves the standard one in place.
        let other = makeGame(index: 2, white: "alice", black: "carol", daysAgo: 2)
        try games.upsert([other])
        try games.link(playerID: player.id, game: other, color: .white)
        let standard = makeAnalysis(for: other, deep: false)
        try analyses.save(standard)
        try analyses.markFailed(gameKey: other.gameKey, message: "test", policyID: DeepReview.identifier)
        XCTAssertEqual(try analyses.analysis(gameKey: other.gameKey)?.id, standard.id)
        XCTAssertEqual(try analyses.header(gameKey: other.gameKey, policyID: DeepReview.identifier)?.status, .failed)
    }

    func testMistakesCountOnlyDeepReviewsAndOnlyThePlayersMoves() throws {
        let player = try makePlayer("alice", providerID: "1")
        let deepGame = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        let standardGame = makeGame(index: 2, white: "alice", black: "carol", daysAgo: 2)
        try games.upsert([deepGame, standardGame])
        try games.link(playerID: player.id, game: deepGame, color: .white)
        try games.link(playerID: player.id, game: standardGame, color: .white)
        try analyses.save(makeAnalysis(for: deepGame, deep: true))
        try analyses.save(makeAnalysis(for: standardGame, deep: false))

        var filters = GameFilters.default
        filters.dateRange = .allTime
        let breakdown = try statistics.errorBreakdown(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(breakdown.games, 1, "a standard analysis labels nothing")
        XCTAssertEqual(breakdown.analysedMoves, 1, "only the player's own moves")
        XCTAssertEqual(breakdown.blunders, 1)
        XCTAssertEqual(breakdown.total, 1)
        XCTAssertEqual(try statistics.averageAccuracy(playerID: player.id, filters: filters, scope: .allDownloaded), 62.5)

        let phases = try statistics.phaseBreakdown(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(phases.first { $0.phase == .opening }?.errors, 1)

        let tags = try statistics.tagCounts(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(Set(tags.map(\.category)), [.pattern(.undefendedPiece), .pattern(.allowedFork)])

        for category in [MistakeCategory.severity(.blunder), .phase(.opening), .pattern(.allowedFork)] {
            let found = try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                   category: category)
            XCTAssertEqual(found.map(\.san), ["e4"], category.title)
        }
        XCTAssertTrue(try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                 category: .pattern(.missedMate)).isEmpty)
        XCTAssertTrue(try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                 category: .outcome(.evaluationLoss)).isEmpty,
                      "a tagged error is never listed under a consequence")
        XCTAssertEqual(try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded).map(\.san),
                       ["e4"], "without a category, every error")
    }

    func testGamesListCarriesRollingAccuraciesAndTheGamesBacklog() throws {
        let player = try makePlayer("alice", providerID: "1")
        let newest = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        let recent = makeGame(index: 2, white: "alice", black: "carol", daysAgo: 10)
        let older = makeGame(index: 3, white: "alice", black: "dave", daysAgo: 41)
        let blitz = makeGame(index: 4, white: "alice", black: "erin", daysAgo: 2, timeClass: .blitz)
        let waiting = makeGame(index: 5, white: "alice", black: "frank", daysAgo: 3)
        try games.upsert([newest, recent, older, blitz, waiting])
        for game in [newest, recent, older, blitz, waiting] {
            try games.link(playerID: player.id, game: game, color: .white)
        }
        for (game, accuracy) in [(newest, 90.0), (recent, 80.0), (older, 40.0), (blitz, 10.0)] {
            var analysis = makeAnalysis(for: game, deep: true)
            analysis.whiteAccuracy = accuracy
            try analyses.save(analysis)
        }
        try statistics.markSolved(gameKey: newest.gameKey, ply: 0)
        _ = try queue.enqueueManual(playerID: player.id, gameKey: waiting.gameKey, bucket: .none,
                                    policyID: DeepReview.identifier)

        let entry = try XCTUnwrap(try games.entry(playerID: player.id, gameKey: newest.gameKey))
        XCTAssertEqual(entry.accuracy, 90)
        XCTAssertEqual(try XCTUnwrap(entry.accuracy30Days), 85, accuracy: 0.001,
                       "30 days back from the game: itself and the game 9 days earlier, never another class")
        XCTAssertEqual(try XCTUnwrap(entry.accuracy12Months), 70, accuracy: 0.001, "the game 40 days earlier joins")
        XCTAssertEqual(entry.errorCount, 1)
        XCTAssertEqual(entry.solvedCount, 1)
        XCTAssertTrue(entry.allMistakesSolved)
        XCTAssertFalse(entry.isQueued)

        let earlier = try XCTUnwrap(try games.entry(playerID: player.id, gameKey: recent.gameKey))
        XCTAssertEqual(try XCTUnwrap(earlier.accuracy30Days), 80, accuracy: 0.001, "later games never count")
        XCTAssertFalse(earlier.allMistakesSolved)

        let queued = try XCTUnwrap(try games.entry(playerID: player.id, gameKey: waiting.gameKey))
        XCTAssertTrue(queued.isQueued)
        XCTAssertNil(queued.accuracy30Days, "no rolling figures without the game's own deep review")

        // Mistakes narrowed to one game ignore filters that would otherwise hide it.
        var filters = GameFilters.default
        filters.timeClass = .blitz
        let found = try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded,
                                               gameKey: recent.gameKey)
        XCTAssertEqual(found.map(\.gameKey), [recent.gameKey])
        let backlog = try statistics.mistakeBacklog(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                    gameKey: newest.gameKey)
        XCTAssertEqual(backlog.errors, 1)
        XCTAssertEqual(backlog.solved, 1)
        XCTAssertEqual(try statistics.averageAccuracy(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                      gameKey: recent.gameKey), 80)
    }

    func testTheMistakesListLabelsEachErrorAndRemembersWhatIsSolved() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        let analysis = makeAnalysis(for: game, deep: true)
        try analyses.save(analysis)

        var filters = GameFilters.default
        filters.dateRange = .allTime
        var backlog = try statistics.mistakeBacklog(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(backlog.errors, 1)
        XCTAssertEqual(backlog.solved, 0)
        XCTAssertEqual(Set(backlog.kinds.map(\.category)), [.pattern(.undefendedPiece), .pattern(.allowedFork)])
        let card = try XCTUnwrap(try statistics.occurrences(playerID: player.id, filters: filters,
                                                            scope: .allDownloaded).first)
        XCTAssertEqual(Set(card.kinds), [.pattern(.undefendedPiece), .pattern(.allowedFork)],
                       "the card carries a label for each pattern")
        let move = try XCTUnwrap(analysis.moves.first { $0.ply == card.ply })
        XCTAssertEqual(card.fenBefore, move.fenBefore, "the card opens on the position before the mistake")
        XCTAssertEqual(card.uci, move.uci)
        XCTAssertEqual(card.scoreBefore, move.scoreBefore)
        XCTAssertEqual(card.bestMoveUCI, move.labels?.bestLineUCI.first)
        XCTAssertFalse(card.isSolved)

        try statistics.markSolved(gameKey: card.gameKey, ply: card.ply)
        try statistics.markSolved(gameKey: card.gameKey, ply: card.ply)
        backlog = try statistics.mistakeBacklog(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(backlog.solved, 1, "solving twice counts once")
        XCTAssertTrue(backlog.kinds.allSatisfy { $0.solved == 1 }, "a solved error is solved under every label it carries")
        XCTAssertEqual(try statistics.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded,
                                                  category: .pattern(.allowedFork)).first?.isSolved, true)

        // A fresh review of the game keeps what was solved.
        try analyses.save(makeAnalysis(for: game, deep: true))
        backlog = try statistics.mistakeBacklog(playerID: player.id, filters: filters, scope: .allDownloaded)
        XCTAssertEqual(backlog.solved, 1)
    }

    func testMistakeDrillsAreScheduledIgnoredAndLedInto() throws {
        let book = MistakeBookRepository(database: database)
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        try analyses.save(makeAnalysis(for: game, deep: true))
        var filters = GameFilters.default
        filters.dateRange = .allTime

        var found = try book.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded)
        let card = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(card.review)
        XCTAssertEqual(card.state(), .new)
        XCTAssertEqual(card.loss, 25)
        XCTAssertEqual(card.scoreAfter, .centipawns(-300))
        XCTAssertEqual(card.bestLineUCI, ["d2d4", "d7d5"])
        XCTAssertEqual(card.replyLineUCI, ["e7e5"])
        XCTAssertEqual(card.openingName, "Scotch Game")

        let now = Date()
        try book.record([card.ref], result: .clean, at: now)
        found = try book.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded)
        var review = try XCTUnwrap(found.first?.review)
        XCTAssertTrue(try XCTUnwrap(found.first).isSolved, "a solve marks it solved")
        XCTAssertEqual(review.drills, 1)
        XCTAssertEqual(review.streak, 1)
        XCTAssertEqual(review.firstResult, "clean")
        XCTAssertEqual(try XCTUnwrap(review.dueAt).timeIntervalSince(now), 3 * 86_400, accuracy: 1)

        try book.record([card.ref], result: .revealed, at: now)
        found = try book.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded)
        review = try XCTUnwrap(found.first?.review)
        XCTAssertEqual(review.drills, 2)
        XCTAssertEqual(review.streak, 0, "anything but a clean solve starts again")
        XCTAssertEqual(review.firstResult, "clean", "the first result stays")
        XCTAssertEqual(try XCTUnwrap(review.dueAt).timeIntervalSince(now), 86_400, accuracy: 1)

        try book.setIgnored([card.ref], true)
        XCTAssertTrue(try book.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded).isEmpty)
        try book.setIgnored([card.ref], false)
        XCTAssertEqual(try book.occurrences(playerID: player.id, filters: filters, scope: .allDownloaded).count, 1)

        XCTAssertNil(try book.leadIn(gameKey: game.gameKey, ply: 0), "nothing comes before the first move")
        let leadIn = try XCTUnwrap(try book.leadIn(gameKey: game.gameKey, ply: 2))
        XCTAssertEqual(leadIn.fen, ChessBoard.startFEN)
        XCTAssertEqual(leadIn.moves, [Move.fromUCI("e2e4")!, Move.fromUCI("e7e5")!])
    }

    func testAnIgnoredMistakeCountsAsDealtWithInGames() throws {
        let book = MistakeBookRepository(database: database)
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        try analyses.save(makeAnalysis(for: game, deep: true))
        XCTAssertFalse(try XCTUnwrap(try games.entry(playerID: player.id, gameKey: game.gameKey)).allMistakesSolved)
        try book.setIgnored([MistakeRef(gameKey: game.gameKey, ply: 0)], true)
        XCTAssertTrue(try XCTUnwrap(try games.entry(playerID: player.id, gameKey: game.gameKey)).allMistakesSolved)
    }

    func testMigratingKeepsSolvedMistakesAsDrilled() throws {
        let path = temporaryDirectory.appendingPathComponent("v10.sqlite").path
        let old = try SQLiteDatabase(path: path)
        try Schema.migrate(old, to: 10)
        try old.run("INSERT INTO solved_mistakes (game_key, ply, solved_at) VALUES ('g', 4, 1000);")
        try Schema.migrate(old)
        let row = try XCTUnwrap(try old.queryOne("SELECT * FROM mistake_reviews WHERE game_key = 'g' AND ply = 4;"))
        XCTAssertEqual(row.int("drills"), 1)
        XCTAssertEqual(row.int("streak"), 1)
        XCTAssertEqual(row.string("first_result"), "solved", "says nothing about first tries")
        XCTAssertEqual(row.double("due_at"), 1000 + 3 * 86_400)
    }

    func testBackupKeepsDeepReviewsAndPrefersThemOnImport() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)
        let deep = makeAnalysis(for: game, deep: true)
        try analyses.save(deep)
        let url = try backup.export(to: temporaryDirectory)

        // The other device has only a standard review of the same game.
        let other = try SQLiteDatabase(path: temporaryDirectory.appendingPathComponent("other.sqlite").path)
        try Schema.migrate(other)
        let otherPlayers = PlayerRepository(database: other)
        let otherGames = GameRepository(database: other)
        let otherAnalyses = AnalysisRepository(database: other)
        try otherGames.upsert([game])
        try otherAnalyses.save(makeAnalysis(for: game, deep: false))
        let otherBackup = BackupService(database: other, players: otherPlayers, games: otherGames, analyses: otherAnalyses)

        let staged = try otherBackup.stage(url: url)
        XCTAssertEqual(try otherBackup.preview(staged).newAnalyses, 1)
        let result = try otherBackup.commit(staged)
        XCTAssertEqual(result.analysesAdded, 1)
        let restored = try XCTUnwrap(try otherAnalyses.analysis(gameKey: game.gameKey))
        XCTAssertTrue(restored.isDeep, "a deep review replaces a standard one")
        XCTAssertEqual(restored.moves, deep.moves)
        XCTAssertEqual(restored.blackAccuracy, 98)
    }

    func testDeepReviewsAreQueuedApartAndKeepTheirPolicy() throws {
        let player = try makePlayer("alice", providerID: "1")
        let game = makeGame(index: 1, white: "alice", black: "bob", daysAgo: 1)
        try games.upsert([game])
        try games.link(playerID: player.id, game: game, color: .white)

        let standard = try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .none)
        let deep = try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .none,
                                           policyID: DeepReview.identifier)
        XCTAssertNotEqual(standard, deep, "a deep review is its own job")
        XCTAssertEqual(try queue.enqueueManual(playerID: player.id, gameKey: game.gameKey, bucket: .none,
                                               policyID: DeepReview.identifier), deep, "and is not queued twice")
        try queue.adoptCurrentPolicy()
        XCTAssertEqual(try queue.item(id: deep)?.policyID, DeepReview.identifier)
        XCTAssertEqual(try queue.activeItem(gameKey: game.gameKey, policyID: DeepReview.identifier)?.id, deep)
    }

    func testUnsafeArchivePathsAreRejected() {
        XCTAssertFalse(ZipArchive.isSafeName("../escape.json"))
        XCTAssertFalse(ZipArchive.isSafeName("/etc/passwd"))
        XCTAssertFalse(ZipArchive.isSafeName("a/b/c/d/e.json"))
        XCTAssertTrue(ZipArchive.isSafeName("manifest.json"))
    }

    func testCorruptBackupIsRefusedBeforeAnyWrite() throws {
        let url = temporaryDirectory.appendingPathComponent("broken.chessbackup")
        try Data("not a zip at all".utf8).write(to: url)
        XCTAssertThrowsError(try backup.stage(url: url))
    }

    func testTimingSamplesProduceAMedianOnlyAfterEnoughData() throws {
        XCTAssertNil(try queue.medianSecondsPerPly())
        try queue.recordTiming(plies: 10, seconds: 10)
        try queue.recordTiming(plies: 10, seconds: 20)
        XCTAssertNil(try queue.medianSecondsPerPly(), "two samples is still estimating")
        try queue.recordTiming(plies: 10, seconds: 30)
        XCTAssertEqual(try queue.medianSecondsPerPly() ?? 0, 2.0, accuracy: 0.001)
    }
}
