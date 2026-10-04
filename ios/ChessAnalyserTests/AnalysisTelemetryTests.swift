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

final class AnalysisTelemetryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let conditions = AnalysisTelemetry.Conditions(
        thermal: "Warm", battery: 0.8, charging: true, lowPower: false, engines: "4E",
        blockers: [], pausedByUser: false, suspendedForBackground: false, appState: "active",
        activeGames: 4, pendingGames: 10, pendingPlies: 700)

    private func lines(_ telemetry: AnalysisTelemetry) throws -> [[String: Any]] {
        telemetry.flush()
        let text = try String(contentsOf: telemetry.fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testSamplesCoverOnlyTheirOwnIntervalAndSplitByEngine() throws {
        let telemetry = AnalysisTelemetry(directory: directory)
        let p = telemetry.channel("P"), e1 = telemetry.channel("E1")
        p.recordSearch(budget: 20_000, seconds: 0.02, nodes: 20_100)
        e1.recordSearch(budget: 20_000, seconds: 0.08, nodes: 20_050)
        e1.recordPly(confirmed: true)
        telemetry.sample(conditions)
        telemetry.sample(conditions)

        let samples = try lines(telemetry).filter { $0["event"] as? String == "sample" }
        XCTAssertEqual(samples.count, 2)
        let first = try XCTUnwrap(samples[0]["work"] as? [String: Any])
        let budget = try XCTUnwrap((first["budgets"] as? [String: Any])?["20000"] as? [String: Any])
        XCTAssertEqual(budget["searches"] as? Int, 2)
        XCTAssertEqual(budget["nodes"] as? Int, 40_150)
        let engines = try XCTUnwrap(first["engines"] as? [String: Any])
        XCTAssertEqual((engines["P"] as? [String: Any])?["nodes"] as? Int, 20_100)
        XCTAssertEqual((engines["E1"] as? [String: Any])?["nodes"] as? Int, 20_050)
        XCTAssertEqual(first["plies"] as? Int, 1)
        XCTAssertEqual(first["confirmedPlies"] as? Int, 1)
        XCTAssertEqual((samples[0]["conditions"] as? [String: Any])?["engines"] as? String, "4E")

        let second = try XCTUnwrap(samples[1]["work"] as? [String: Any])
        XCTAssertEqual(second["plies"] as? Int, 0, "a sample starts a new interval")
    }

    func testEachEnginesGameReportsOnlyItsOwnWork() throws {
        let telemetry = AnalysisTelemetry(directory: directory)
        let p = telemetry.channel("P"), e1 = telemetry.channel("E1")
        p.recordPly(confirmed: false)  // before the game: not part of it
        p.gameStarted(plies: 40, bulk: true)
        e1.gameStarted(plies: 30, bulk: true)
        p.recordPly(confirmed: false)
        p.recordPly(confirmed: true)
        e1.recordPly(confirmed: false)
        p.gameEnded(outcome: "finished")
        e1.gameEnded(outcome: "interrupted")

        let ended = try lines(telemetry).filter { $0["event"] as? String == "gameEnded" }
        let byEngine = Dictionary(uniqueKeysWithValues: ended.map { ($0["engine"] as? String ?? "", $0) })
        XCTAssertEqual(byEngine["P"]?["outcome"] as? String, "finished")
        XCTAssertEqual((byEngine["P"]?["work"] as? [String: Any])?["plies"] as? Int, 2)
        XCTAssertEqual((byEngine["E1"]?["work"] as? [String: Any])?["plies"] as? Int, 1)
    }

    func testAnalyzerReportsEverySearchAndPly() throws {
        guard let engine = StockfishEngine() else { throw XCTSkip("Stockfish unavailable") }
        let telemetry = AnalysisTelemetry(directory: directory)
        let pgn = "[Event \"t\"]\n\n1. e4 e5 2. Nf3 Nc6"
        let parsed = PGNParser.parse(pgn)
        let game = GameRecord(gameKey: "t", url: "https://example.com/t", uuid: "t", pgn: pgn,
                              startFEN: parsed.startFEN,
                              moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                              endTime: Date(), timeClass: .rapid, timeControl: "600", rules: "chess", rated: true,
                              white: GameSide(username: "w", rating: 1500, resultCode: "win"),
                              black: GameSide(username: "b", rating: 1500, resultCode: "resigned"),
                              eco: nil, ecoURL: nil, openingName: nil, parseState: .parsed,
                              plyCount: parsed.moves.count)
        _ = try GameAnalyzer(engine: engine, telemetry: telemetry.channel("P"))
            .analyze(game: game, cancellation: CancellationToken())
        telemetry.sample(conditions)

        let work = try XCTUnwrap(try lines(telemetry).first?["work"] as? [String: Any])
        XCTAssertEqual(work["plies"] as? Int, 4)
        let standard = try XCTUnwrap((work["budgets"] as? [String: Any])?[String(AnalysisPolicy.standardNodes)] as? [String: Any])
        XCTAssertEqual(standard["searches"] as? Int, 5, "every position once, the first move's included")
        XCTAssertGreaterThan(standard["seconds"] as? Double ?? 0, 0)
    }
}
