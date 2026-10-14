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

final class LichessTests: XCTestCase {

    private var database: SQLiteDatabase!
    private var players: PlayerRepository!
    private var games: GameRepository!
    private var archives: ArchiveRepository!
    private var sync: ArchiveSyncService!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        try Schema.migrate(database)
        players = PlayerRepository(database: database)
        games = GameRepository(database: database)
        archives = ArchiveRepository(database: database)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeLichess.self]
        let session = URLSession(configuration: configuration)
        sync = ArchiveSyncService(client: ChessComClient(session: session), lichess: LichessClient(session: session),
                                  players: players, games: games, archives: archives)
        FakeLichess.reset()
    }

    override func tearDownWithError() throws {
        FakeLichess.reset()
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: Mapping

    /// A game exactly as the export sends it, trimmed to one line of moves.
    private let exportedLine = """
    {"id":"HK6LnPBQ","rated":true,"variant":"standard","speed":"blitz","perf":"blitz","createdAt":1791480882466,"lastMoveAt":1791481356242,"status":"resign","source":"pool","players":{"white":{"user":{"name":"PABLO_CALCATERRA","id":"pablo_calcaterra"},"rating":1726,"ratingDiff":6},"black":{"user":{"name":"thibault","id":"thibault"},"rating":1755,"ratingDiff":-6}},"winner":"white","opening":{"eco":"D15","name":"Slav Defense: Three Knights Variation","ply":7},"moves":"d4 d5","pgn":"[Event \\"rated blitz game\\"]\\n[Site \\"https://lichess.org/HK6LnPBQ\\"]\\n[White \\"PABLO_CALCATERRA\\"]\\n[Black \\"thibault\\"]\\n[Result \\"1-0\\"]\\n[ECO \\"D15\\"]\\n[Opening \\"Slav Defense: Three Knights Variation\\"]\\n\\n1. d4 d5 1-0\\n","clock":{"initial":300,"increment":3,"totalTime":420}}
    """

    func testAnExportedGameBecomesAStoredGameInTheSharedVocabulary() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exportedLine.utf8)) as? [String: Any])
        let exported = try XCTUnwrap(LichessClient.exportedGame(object))
        XCTAssertEqual(exported.createdAt, 1791480882466)
        let game = try XCTUnwrap(exported.game)
        XCTAssertEqual(game.uuid, "lichess:HK6LnPBQ", "the key keeps the case-sensitive Lichess ID")
        XCTAssertEqual(game.url, "https://lichess.org/HK6LnPBQ")
        XCTAssertEqual(game.timeControl, "300+3")
        XCTAssertEqual(game.whiteResult, "win")
        XCTAssertEqual(game.blackResult, "resigned")
        XCTAssertEqual(game.endTime.timeIntervalSince1970, 1791481356.242, accuracy: 0.001)

        let mapped = try XCTUnwrap(ArchiveSyncService.records(from: [game]).first)
        XCTAssertEqual(mapped.record.gameKey, "lichess:HK6LnPBQ")
        XCTAssertEqual(mapped.record.timeClass, .blitz)
        XCTAssertEqual(mapped.record.openingName, "Slav Defense: Three Knights Variation")
        XCTAssertEqual(mapped.color(for: "thibault"), .black)
        XCTAssertEqual(mapped.record.black.outcome, .loss)
    }

    func testEveryWayALichessGameEndsMapsToAResultCode() {
        XCTAssertEqual(LichessClient.results(status: "mate", winner: "black")?.white, "checkmated")
        XCTAssertEqual(LichessClient.results(status: "mate", winner: "black")?.black, "win")
        XCTAssertEqual(LichessClient.results(status: "outoftime", winner: "white")?.black, "timeout")
        XCTAssertEqual(LichessClient.results(status: "outoftime", winner: nil)?.white, "timevsinsufficient")
        XCTAssertEqual(LichessClient.results(status: "timeout", winner: "white")?.black, "abandoned")
        XCTAssertEqual(LichessClient.results(status: "draw", winner: nil)?.white, "draw")
        XCTAssertEqual(LichessClient.results(status: "stalemate", winner: nil)?.black, "stalemate")
        XCTAssertEqual(LichessClient.results(status: "insufficientMaterialClaim", winner: nil)?.white, "insufficient")
        for unfinished in ["aborted", "noStart", "created", "started", "unknownFinish"] {
            XCTAssertNil(LichessClient.results(status: unfinished, winner: nil), unfinished)
        }
        XCTAssertEqual(ResultCodes.outcome(for: "draw"), .draw)
    }

    func testClassicalAndCorrespondenceAreKeptAndUltraBulletAndVariantsAreNot() {
        let classical = ProviderGame.lichess(id: "a", speed: "classical")
        let correspondence = ProviderGame.lichess(id: "b", speed: "correspondence", daysPerTurn: 3)
        let ultra = ProviderGame.lichess(id: "c", speed: "ultraBullet")
        let atomic = ProviderGame.lichess(id: "d", speed: "blitz", variant: "atomic")
        let records = ArchiveSyncService.records(from: [classical, correspondence, ultra, atomic].compactMap { $0 })
        XCTAssertEqual(records.map(\.record.timeClass), [.classical, .daily])
        XCTAssertEqual(records.last?.record.timeControl, "1/259200")
    }

    func testAClosedAccountCannotBeFollowedAndAnOpenOneIsNamespaced() throws {
        XCTAssertThrowsError(try LichessClient.profile(["id": "gone", "username": "Gone", "disabled": true]))
        let profile = try LichessClient.profile(["id": "dr", "username": "Dr", "title": "GM",
                                                 "profile": ["flag": "NO"], "count": ["all": 12],
                                                 "perfs": ["correspondence": ["games": 3]]])
        XCTAssertEqual(profile.provider, .lichess)
        XCTAssertEqual(profile.providerID, "lichess:dr")
        XCTAssertEqual(profile.country, "NO")
        XCTAssertEqual(profile.gameCount, 12)
        XCTAssertTrue(profile.playsCorrespondence)
    }

    // MARK: Identity

    func testTheSameNameOnBothSitesIsTwoPlayers() throws {
        try players.save(TrackedPlayer(provider: .chessCom, providerID: "123", username: "hikaru", displayUsername: "Hikaru"))
        try players.save(TrackedPlayer(provider: .lichess, providerID: "lichess:hikaru", username: "hikaru", displayUsername: "Hikaru"))
        XCTAssertEqual(try players.all().count, 2)
        XCTAssertEqual(try players.player(username: "hikaru", provider: .lichess)?.providerID, "lichess:hikaru")
        XCTAssertEqual(try players.player(username: "Hikaru", provider: .chessCom)?.providerID, "123")
    }

    func testMigratingMakesEveryExistingPlayerAChessComPlayer() throws {
        let path = temporaryDirectory.appendingPathComponent("v8.sqlite").path
        let old = try SQLiteDatabase(path: path)
        try Schema.migrate(old, to: 8)
        try old.run("""
            INSERT INTO players (id, provider_id, username, display_username, created_at)
            VALUES ('\(UUID().uuidString)', '1', 'alice', 'alice', 0);
            """)
        try Schema.migrate(old)
        let migrated = PlayerRepository(database: old)
        XCTAssertEqual(try migrated.player(username: "alice", provider: .chessCom)?.provider, .chessCom)
        XCTAssertNil(try migrated.player(username: "alice", provider: .lichess))
    }

    // MARK: Download

    private func lichessPlayer() throws -> TrackedPlayer {
        let player = TrackedPlayer(provider: .lichess, providerID: "lichess:alice", username: "alice", displayUsername: "Alice")
        try players.save(player)
        return player
    }

    func testAFirstImportReadsTheWholeHistoryNewestFirst() async throws {
        FakeLichess.games = FakeLichess.history(count: 250)
        let player = try lichessPlayer()

        let outcome = await sync.refresh(player: player, scope: .freeWindow) { _ in }

        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.boundedScopeComplete)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 250)
        let cursor = try archives.cursor(playerID: player.id)
        XCTAssertTrue(cursor.complete)
        XCTAssertEqual(cursor.newest, FakeLichess.games.map(\.createdAt).max())
        let exports = FakeLichess.exportQueries()
        XCTAssertEqual(exports.count, 1)
        XCTAssertNil(exports[0]["since"] ?? nil)
        XCTAssertEqual(exports[0]["perfType"], "bullet,blitz,rapid,classical,correspondence")
    }

    func testALaterRefreshOnlyAsksForGamesSinceTheNewestOne() async throws {
        FakeLichess.games = FakeLichess.history(count: 30)
        let player = try lichessPlayer()
        _ = await sync.refresh(player: player, scope: .freeWindow) { _ in }
        let newest = try XCTUnwrap(archives.cursor(playerID: player.id).newest)

        FakeLichess.games += (1...3).map { FakeLichess.Game(index: 1_000 + $0, createdAt: newest + $0 * 60_000) }
        FakeLichess.requests.removeAll()
        let outcome = await sync.refresh(player: player, scope: .freeWindow) { _ in }

        XCTAssertNil(outcome.error)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 33)
        XCTAssertEqual(try archives.cursor(playerID: player.id).newest, newest + 180_000)
        let exports = FakeLichess.exportQueries()
        XCTAssertEqual(exports.count, 1, "a complete history needs no backfill")
        XCTAssertEqual(exports[0]["since"], String(newest - ArchiveSyncService.lichessOverlap))
    }

    func testAnInterruptedImportCarriesOnFromWhereItStopped() async throws {
        FakeLichess.games = FakeLichess.history(count: 250)
        FakeLichess.breakAfter = 120
        let player = try lichessPlayer()

        let broken = await sync.refresh(player: player, scope: .freeWindow) { _ in }
        XCTAssertEqual(broken.error, .offline)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 100, "only whole batches are kept")
        XCTAssertFalse(try archives.cursor(playerID: player.id).complete)

        FakeLichess.breakAfter = nil
        let resumed = await sync.refresh(player: player, scope: .freeWindow) { _ in }
        XCTAssertNil(resumed.error)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 250)
        XCTAssertTrue(try archives.cursor(playerID: player.id).complete)
    }

    func testTheFreePlanStopsOnceTheLatestThousandGamesAreStored() async throws {
        FakeLichess.games = FakeLichess.history(count: 1_200)
        let player = try lichessPlayer()

        let outcome = await sync.refresh(player: player, scope: .freeWindow) { _ in }

        XCTAssertNil(outcome.error)
        XCTAssertEqual(try games.totalGameCount(playerID: player.id), 1_000)
        XCTAssertEqual(outcome.windowCount, 1_000)
        XCTAssertFalse(try archives.cursor(playerID: player.id).complete, "older games are left for Premium")
        XCTAssertEqual(FakeLichess.exportQueries().first?["max"], "1000")
    }

    func testARateLimitStopsTheRefreshAndIsReported() async throws {
        FakeLichess.rateLimited = true
        let player = try lichessPlayer()
        let outcome = await sync.refresh(player: player, scope: .freeWindow) { _ in }
        XCTAssertEqual(outcome.status, .rateLimited)
        XCTAssertEqual(outcome.error, .rateLimited(retryAfter: 60))
    }
}

// MARK: - A fake Lichess

private extension ProviderGame {
    static func lichess(id: String, speed: String, variant: String = "standard", daysPerTurn: Int? = nil) -> ProviderGame? {
        var object = FakeLichess.Game(index: 0, createdAt: 1_700_000_000_000).json
        object["id"] = id
        object["speed"] = speed
        object["variant"] = variant
        if let daysPerTurn {
            object["clock"] = nil
            object["daysPerTurn"] = daysPerTurn
        }
        return LichessClient.exportedGame(object)?.game
    }
}

/// Serves `/api/user/alice` and `/api/games/user/alice` from an in-memory history, honouring
/// `since`, `until` (inclusive) and `max`, and records every request.
private final class FakeLichess: URLProtocol {
    struct Game {
        var index: Int
        var createdAt: Int

        var json: [String: Any] {
            ["id": "G\(index)", "rated": true, "variant": "standard", "speed": "rapid",
             "createdAt": createdAt, "lastMoveAt": createdAt + 600_000, "status": "mate", "winner": "white",
             "players": ["white": ["user": ["name": "Alice", "id": "alice"], "rating": 1500],
                         "black": ["user": ["name": "Bob", "id": "bob"], "rating": 1490]],
             "pgn": "[Event \"t\"]\n\n1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0\n",
             "clock": ["initial": 600, "increment": 0, "totalTime": 600]]
        }
    }

    static var games: [Game] = []
    static var requests: [URL] = []
    /// When set, the export stream fails after this many games.
    static var breakAfter: Int?
    static var rateLimited = false

    static func reset() {
        games = []
        requests = []
        breakAfter = nil
        rateLimited = false
    }

    /// Games an hour apart, so a long history reaches well past the new-games overlap.
    static func history(count: Int) -> [Game] {
        let start = 1_700_000_000_000
        return (0..<count).map { Game(index: $0, createdAt: start + $0 * 3_600_000) }
    }

    static func exportQueries() -> [[String: String?]] {
        requests.filter { $0.path.hasPrefix("/api/games/user/") }.map { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lichess.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.append(url)
        if Self.rateLimited { return respond(429, Data()) }

        if url.path == "/api/user/alice" {
            let profile: [String: Any] = ["id": "alice", "username": "Alice", "count": ["all": Self.games.count]]
            return respond(200, try! JSONSerialization.data(withJSONObject: profile))
        }
        guard url.path == "/api/games/user/alice" else { return respond(404, Data()) }

        let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        var window = Self.games.sorted { $0.createdAt > $1.createdAt }
        if let since = query["since"].flatMap(Int.init) { window = window.filter { $0.createdAt >= since } }
        if let until = query["until"].flatMap(Int.init) { window = window.filter { $0.createdAt <= until } }
        if let max = query["max"].flatMap(Int.init) { window = Array(window.prefix(max)) }

        let lines = window.map { String(data: try! JSONSerialization.data(withJSONObject: $0.json), encoding: .utf8)! + "\n" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let breakAfter = Self.breakAfter, lines.count > breakAfter {
            client?.urlProtocol(self, didLoad: Data(lines.prefix(breakAfter).joined().utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        client?.urlProtocol(self, didLoad: Data(lines.joined().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(_ status: Int, _ body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
