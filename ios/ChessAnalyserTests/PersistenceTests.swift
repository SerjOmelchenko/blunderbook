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
                                    status: .complete, nextPly: 0,
                                    whiteAccuracy: 90, blackAccuracy: 80)
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
                                    status: .complete, nextPly: 0,
                                    whiteAccuracy: 90, blackAccuracy: 80)
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
                                    status: .complete, nextPly: 2,
                                    whiteAccuracy: 55, blackAccuracy: 60)
        analysis.completedAt = Date()
        analysis.moves = [MoveAnalysis(ply: 0, mover: .white, san: "e4", uci: "e2e4",
                                       fenBefore: ChessBoard.startFEN,
                                       scoreBefore: .centipawns(20), scoreAfter: .centipawns(-400),
                                       bestMoveSAN: "d4", bestLineSAN: [], bestLineUCI: [],
                                       replyLineSAN: [], replyLineUCI: [], depth: 8, nodes: 1000,
                                       confirmed: true, loss: 40, accuracy: 15, severity: .blunder,
                                       phase: .opening, tags: [], consequence: .evaluationLoss,
                                       explanation: "", isBest: false)]
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
                                    status: .complete, nextPly: 1,
                                    whiteAccuracy: 88.5, blackAccuracy: 77.25)
        analysis.completedAt = Date()
        analysis.moves = [MoveAnalysis(ply: 0, mover: .white, san: "e4", uci: "e2e4",
                                       fenBefore: ChessBoard.startFEN,
                                       scoreBefore: .centipawns(20), scoreAfter: .centipawns(5),
                                       bestMoveSAN: nil, bestLineSAN: ["e4", "e5"], bestLineUCI: ["e2e4", "e7e5"],
                                       replyLineSAN: ["e5"], replyLineUCI: ["e7e5"], depth: 9, nodes: 1234,
                                       confirmed: false, loss: 1.2, accuracy: 96.4, severity: nil,
                                       phase: .opening, tags: [], consequence: .evaluationLoss,
                                       explanation: "Fine.", isBest: true)]
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
        XCTAssertEqual(restored?.whiteAccuracy ?? 0, 88.5, accuracy: 0.001)
        XCTAssertEqual(restored?.moves.first?.san, "e4")
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
                                status: .complete, nextPly: 0, whiteAccuracy: 99, blackAccuracy: 99)
        mine.completedAt = Date()
        try analyses.save(mine)

        let url = try backup.export(to: temporaryDirectory)
        // Re-importing into the same database must not overwrite what is already complete.
        let staged = try backup.stage(url: url)
        let result = try backup.commit(staged)
        XCTAssertEqual(result.analysesKept, 1)
        XCTAssertEqual(result.gamesSkipped, 1)
        XCTAssertEqual(try analyses.analysis(gameKey: game.gameKey)?.whiteAccuracy, 99)
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
