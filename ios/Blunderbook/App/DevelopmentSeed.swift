//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

#if DEBUG
import Foundation

/// Development-only fixture loader.
///
/// Launch with `-seed-demo` to fill the database with a tracked player and a handful of real
/// games, so every screen can be inspected without waiting for a download. It is compiled out of
/// release builds and never runs unless the argument is present.
@MainActor
enum DevelopmentSeed {
    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-seed-demo")
    }

    struct Fixture {
        var pgn: String
        var demoPlaysWhite: Bool
        var timeClass: TimeClass
        var timeControl: String
        var rated: Bool
        var daysAgo: Double
        var demoRating: Int
        var opponentRating: Int
        var analyse: Bool
        /// How the loser's game ended, in Chess.com's result codes.
        var loserResult = "checkmated"
    }

    nonisolated static let username = "demoplayer"

    private nonisolated static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `-start-tab games`, `-open-game demo-0`, `-open-route queue`, `-open-sheet settings`.
    nonisolated static var startupTab: RootTab? {
        argument("-start-tab").flatMap(RootTab.init(rawValue:))
    }

    nonisolated static var startupRoute: Route? {
        if let key = argument("-open-game") {
            return .gameReview(gameKey: key, ply: Int(argument("-ply") ?? ""))
        }
        switch argument("-open-route") {
        case "queue": return .queue
        case "how": return .howAnalysisWorks
        case "about": return .about
        default: return nil
        }
    }

    nonisolated static var startupSheet: String? { argument("-open-sheet") }

    /// `-open-game KEY -ply N -explore both|engine`: Explore from that move of the game.
    nonisolated static var opensExplore: Bool { argument("-explore") != nil }

    nonisolated static var startupExploreMode: ExploreModel.Mode {
        argument("-explore") == "engine" ? .engine : .bothSides
    }

    /// `-open-route first-mistake`: the newest error in the backlog, as a puzzle.
    nonisolated static var opensFirstMistake: Bool { argument("-open-route") == "first-mistake" }

    /// `-queue-game demo-3`: queues that game's in-depth review a moment after launch, to watch
    /// its rings in Games spin, then (left untouched) fly you through them into the game.
    nonisolated static var queuedGame: String? { argument("-queue-game") }

    /// `-unlock-mistakes`: the Mistakes tab opens without Premium, to check it on real data.
    nonisolated static var unlocksMistakes: Bool { ProcessInfo.processInfo.arguments.contains("-unlock-mistakes") }

    /// `-scroll-to leak`: Mistakes (or its preview) opens scrolled to that part: `leak`, `kinds`.
    nonisolated static var scrollTarget: String? { argument("-scroll-to").map { "mistakes-\($0)" } }

    /// `-scroll-bottom`: Analytics opens scrolled to its end, to see the analysis rows.
    nonisolated static var scrollsToBottom: Bool { ProcessInfo.processInfo.arguments.contains("-scroll-bottom") }

    /// `-time-class daily`, `-date-range week` — presets the shared filter so a screen can be
    /// inspected in a given state without tapping.
    nonisolated static var startupTimeClass: TimeClass? {
        argument("-time-class").flatMap(TimeClass.init(rawValue:))
    }

    nonisolated static var startupDateRange: DateRange? {
        switch argument("-date-range") {
        case "week": return .lastWeek
        case "month": return .lastMonth
        case "90": return .last90Days
        case "year": return .lastYear
        case "all": return .allTime
        default: return nil
        }
    }

    static func seed(into model: AppModel) {
        guard model.trackedPlayers.isEmpty else { return }

        // `-seed-provider lichess` makes the demo player a Lichess one, to check Lichess screens.
        let provider = argument("-seed-provider").flatMap(Provider.init(rawValue:)) ?? .chessCom
        var player = TrackedPlayer(provider: provider,
                                   providerID: provider == .lichess ? "lichess:demoplayer" : "900000001",
                                   username: username,
                                   displayUsername: "demoplayer")
        player.status = .upToDate
        player.lastChecked = Date()
        player.lastSuccessfulRefresh = Date()
        player.hasVerifiedWindow = true
        try? model.players.save(player)

        var records: [GameRecord] = []
        for (index, fixture) in fixtures.enumerated() {
            let parsed = PGNParser.parse(fixture.pgn)
            let key = "demo-\(index)"
            let opponent = "opponent\(index + 1)"
            let white = fixture.demoPlaysWhite ? username : opponent
            let black = fixture.demoPlaysWhite ? opponent : username
            let result = parsed.result
            let whiteResult: String
            let blackResult: String
            switch result {
            case "1-0": whiteResult = "win"; blackResult = fixture.loserResult
            case "0-1": whiteResult = fixture.loserResult; blackResult = "win"
            default: whiteResult = "agreed"; blackResult = "agreed"
            }
            let record = GameRecord(gameKey: key,
                                    url: "https://www.chess.com/game/live/\(index)",
                                    uuid: key,
                                    pgn: fixture.pgn,
                                    startFEN: parsed.startFEN,
                                    moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                                    endTime: Date().addingTimeInterval(-fixture.daysAgo * 86_400),
                                    timeClass: fixture.timeClass,
                                    timeControl: fixture.timeControl,
                                    rules: "chess",
                                    rated: fixture.rated,
                                    white: GameSide(username: white,
                                                    rating: fixture.demoPlaysWhite ? fixture.demoRating : fixture.opponentRating,
                                                    resultCode: whiteResult),
                                    black: GameSide(username: black,
                                                    rating: fixture.demoPlaysWhite ? fixture.opponentRating : fixture.demoRating,
                                                    resultCode: blackResult),
                                    eco: parsed.tags["ECO"],
                                    ecoURL: parsed.tags["ECOUrl"],
                                    openingName: ArchiveSyncService.openingName(tags: parsed.tags, ecoURL: nil),
                                    parseState: parsed.isValid ? .parsed : .malformed,
                                    plyCount: parsed.moves.count)
            records.append(record)
        }

        try? model.games.upsert(records)
        for (index, record) in records.enumerated() {
            try? model.games.link(playerID: player.id,
                                  game: record,
                                  color: fixtures[index].demoPlaysWhite ? .white : .black)
        }
        _ = try? model.games.publishFreeWindow(playerID: player.id, limit: ArchiveSyncService.freeWindowLimit)

        for key in zip(records, fixtures).filter({ $0.1.analyse }).map(\.0.gameKey) {
            _ = try? model.queue.enqueueManual(playerID: player.id, gameKey: key, bucket: .none)
        }

        model.reloadPlayers()
        model.touch()
    }

    // Real, legal games so every board, line and evaluation on screen is genuine.
    nonisolated static let fixtures: [Fixture] = [
        Fixture(pgn: """
            [Event "Demo"]
            [Site "Paris"]
            [Result "1-0"]
            [ECO "C41"]
            [Opening "Philidor Defense"]

            1.e4 e5 2.Nf3 d6 3.d4 Bg4 4.dxe5 Bxf3 5.Qxf3 dxe5 6.Bc4 Nf6 7.Qb3 Qe7
            8.Nc3 c6 9.Bg5 b5 10.Nxb5 cxb5 11.Bxb5+ Nbd7 12.O-O-O Rd8 13.Rxd7 Rxd7
            14.Rd1 Qe6 15.Bxd7+ Nxd7 16.Qb8+ Nxb8 17.Rd8# 1-0
            """,
                demoPlaysWhite: true, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 0.02, demoRating: 1462, opponentRating: 1450, analyse: true),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "0-1"]
            [ECO "A00"]
            [Opening "Barnes Opening"]

            1.f3 e5 2.g4 Qh4# 0-1
            """,
                demoPlaysWhite: true, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 2, demoRating: 1450, opponentRating: 1471, analyse: true),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "C50"]
            [Opening "Italian Game"]

            1.e4 e5 2.Bc4 Nc6 3.Qh5 Nf6 4.Qxf7# 1-0
            """,
                demoPlaysWhite: false, timeClass: .blitz, timeControl: "180", rated: true,
                daysAgo: 3, demoRating: 1441, opponentRating: 1502, analyse: true),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "C33"]
            [Opening "King's Gambit Accepted"]

            1.e4 e5 2.f4 exf4 3.Bc4 Qh4+ 4.Kf1 b5 5.Bxb5 Nf6 6.Nf3 Qh6 7.d3 Nh5
            8.Nh4 Qg5 9.Nf5 c6 10.g4 Nf6 11.Rg1 cxb5 12.h4 Qg6 13.h5 Qg5 14.Qf3 Ng8
            15.Bxf4 Qf6 16.Nc3 Bc5 17.Nd5 Qxb2 18.Bd6 Bxg1 19.e5 Qxa1+ 20.Ke2 Na6
            21.Nxg7+ Kd8 22.Qf6+ Nxf6 23.Be7# 1-0
            """,
                demoPlaysWhite: true, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 5, demoRating: 1438, opponentRating: 1444, analyse: true),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1/2-1/2"]
            [ECO "D37"]
            [Opening "Queen's Gambit Declined"]

            1.d4 d5 2.c4 e6 3.Nc3 Nf6 4.Bg5 Be7 5.e3 O-O 6.Nf3 Nbd7 7.Rc1 c6
            8.Bd3 dxc4 9.Bxc4 Nd5 10.Bxe7 Qxe7 1/2-1/2
            """,
                demoPlaysWhite: false, timeClass: .rapid, timeControl: "900+10", rated: true,
                daysAgo: 6, demoRating: 1433, opponentRating: 1428, analyse: true),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "C54"]
            [Opening "Italian Game: Evans Gambit"]

            1.e4 e5 2.Nf3 Nc6 3.Bc4 Bc5 4.b4 Bxb4 5.c3 Ba5 6.d4 exd4 7.O-O d3
            8.Qb3 Qf6 9.e5 Qg6 10.Re1 Nge7 11.Ba3 b5 12.Qxb5 Rb8 13.Qa4 Bb6
            14.Nbd2 Bb7 15.Ne4 Qf5 16.Bxd3 Qh5 17.Nf6+ gxf6 18.exf6 Rg8 19.Rad1 Qxf3
            20.Rxe7+ Nxe7 21.Qxd7+ Kxd7 22.Bf5+ Ke8 23.Bd7+ Kf8 24.Bxe7# 1-0
            """,
                demoPlaysWhite: true, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 8, demoRating: 1421, opponentRating: 1465, analyse: false),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "C41"]
            [Opening "Philidor Defense"]

            1.e4 e5 2.Nf3 d6 3.Bc4 Bg4 4.Nc3 g6 5.Nxe5 Bxd1 6.Bxf7+ Ke7 7.Nd5# 1-0
            """,
                demoPlaysWhite: false, timeClass: .bullet, timeControl: "60", rated: true,
                daysAgo: 9, demoRating: 1418, opponentRating: 1409, analyse: false),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "0-1"]
            [ECO "B01"]
            [Opening "Scandinavian Defense"]

            1.e4 d5 2.exd5 Qxd5 3.Nc3 Qa5 4.d4 Nf6 5.Nf3 c6 6.Bc4 Bf5 7.Bd2 e6
            8.Qe2 Bb4 9.O-O-O Nbd7 10.a3 O-O-O 11.axb4 Qxb4 12.Nd5 0-1
            """,
                demoPlaysWhite: false, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 12, demoRating: 1412, opponentRating: 1440, analyse: false),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "B20"]
            [Opening "Sicilian Defense"]

            1.e4 c5 2.Nf3 d6 3.d4 cxd4 4.Nxd4 Nf6 5.Nc3 a6 6.Be3 e5 7.Nb3 Be7
            8.f3 Be6 9.Qd2 O-O 10.O-O-O Nbd7 11.g4 b5 12.g5 b4 13.Ne2 Ne8 14.f4 a5 1-0
            """,
                demoPlaysWhite: true, timeClass: .daily, timeControl: "1/86400", rated: true,
                daysAgo: 16, demoRating: 1405, opponentRating: 1398, analyse: false),

        Fixture(pgn: """
            [Event "Demo"]
            [Result "0-1"]
            [ECO "C20"]
            [Opening "King's Pawn Game"]

            1.e4 e5 2.d4 exd4 3.Qxd4 Nc6 4.Qe3 Nf6 5.Nc3 Bb4 6.Bd2 O-O 7.O-O-O Re8
            8.Qg3 Nxe4 9.Nxe4 Rxe4 10.Bf4 Qf6 11.Nf3 Rxf4 0-1
            """,
                demoPlaysWhite: true, timeClass: .blitz, timeControl: "300", rated: false,
                daysAgo: 20, demoRating: 1399, opponentRating: 1430, analyse: false),

        // The game from the review walkthrough, with Chess.com's clock comments, so the
        // review's clock times, scramble and summary can be seen: `-open-game demo-10`.
        Fixture(pgn: """
            [Event "Demo"]
            [Result "1-0"]
            [ECO "C41"]
            [Opening "Philidor Defense"]
            [TimeControl "600"]

            1. e4 {[%clk 0:09:59]} 1... e5 {[%clk 0:09:58]} 2. Nf3 {[%clk 0:09:57]}
            2... d6 {[%clk 0:09:55]} 3. d4 {[%clk 0:09:55]} 3... exd4 {[%clk 0:09:51]}
            4. Nxd4 {[%clk 0:09:52]} 4... Nf6 {[%clk 0:09:48]} 5. Nc3 {[%clk 0:09:48]}
            5... Be7 {[%clk 0:09:43]} 6. Bc4 {[%clk 0:09:37]} 6... O-O {[%clk 0:09:35]}
            7. O-O {[%clk 0:09:31]} 7... Nc6 {[%clk 0:09:23]} 8. Bg5 {[%clk 0:09:07]}
            8... Nxe4 {[%clk 0:09:14]} 9. Nxe4 {[%clk 0:09:04]} 9... Bxg5 {[%clk 0:09:00]}
            10. Nxc6 {[%clk 0:08:49]} 10... bxc6 {[%clk 0:08:53]} 11. Nxg5 {[%clk 0:08:40]}
            11... Qxg5 {[%clk 0:08:47]} 12. Re1 {[%clk 0:08:02]} 12... Ba6 {[%clk 0:08:26]}
            13. Qd3 {[%clk 0:07:58]} 13... Bxc4 {[%clk 0:08:16]} 14. Qxc4 {[%clk 0:07:51]}
            14... Rab8 {[%clk 0:07:51]} 15. Qxc6 {[%clk 0:07:20]} 15... Rxb2 {[%clk 0:07:39]}
            16. Kh1 {[%clk 0:07:18]} 16... Qd2 {[%clk 0:07:21]} 17. Qxc7 {[%clk 0:06:06]}
            17... Qxf2 {[%clk 0:07:12]} 18. Rac1 {[%clk 0:05:30]} 18... Rxa2 {[%clk 0:06:55]}
            19. Red1 {[%clk 0:04:35]} 19... h6 {[%clk 0:06:33]} 20. Rxd6 {[%clk 0:03:49]}
            20... Qf4 {[%clk 0:06:14]} 21. Rcd1 {[%clk 0:01:51]} 21... Re8 {[%clk 0:06:00]}
            22. Rd7 {[%clk 0:01:24]} 22... Qf5 {[%clk 0:05:44]} 23. h3 {[%clk 0:01:02]}
            23... Re3 {[%clk 0:05:33]} 24. R7d3 {[%clk 0:00:43]} 24... Rxd3 {[%clk 0:05:24]}
            25. Rxd3 {[%clk 0:00:37]} 25... Ra1+ {[%clk 0:05:11]} 26. Kh2 {[%clk 0:00:29]}
            26... Re1 {[%clk 0:05:03]} 27. Rc3 {[%clk 0:00:24]} 27... Qf6 {[%clk 0:04:48]}
            28. Rd3 {[%clk 0:00:20]} 28... g6 {[%clk 0:04:36]} 29. Qd8+ {[%clk 0:00:15]}
            29... Kh7 {[%clk 0:04:30]} 30. Qxf6 {[%clk 0:00:12]} 1-0
            """,
                demoPlaysWhite: true, timeClass: .rapid, timeControl: "600", rated: true,
                daysAgo: 0.01, demoRating: 1552, opponentRating: 1541, analyse: true, loserResult: "resigned"),
    ]
}
#endif
