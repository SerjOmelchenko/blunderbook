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

/// Builds `Resources/OpeningEvaluations.tsv`: every position of the named openings up to
/// `PositionCache.maxPly`, searched by the app's own engine at the free levels (Quick and Standard),
/// exactly as a review searches it. Deep and Deepest are left to the device's own cache: few people
/// use them, and building them would take many hours each. Run it again whenever the engine, its network or a level's budget changes;
/// until then the app ignores the file. Not a test: it runs only when asked, on the simulator,
/// which uses the Mac's cores — half of what a review may use, at low priority, so the Mac stays
/// usable while it runs (about 1–2 hours for Standard on an M5). Run it on mains power only.
///
///     TEST_RUNNER_BLUNDERBOOK_BUILD_OPENINGS=/path/to/OpeningEvaluations.tsv \
///     TEST_RUNNER_BLUNDERBOOK_LEVELS=quick,standard \
///     xcodebuild test -scheme Blunderbook -destination '<simulator>' \
///         -only-testing:BlunderbookTests/OpeningEvaluationsBuilder
///
/// It appends to the file and skips what is already there, so a stopped run carries on.
final class OpeningEvaluationsBuilder: XCTestCase {

    func testBuild() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BLUNDERBOOK_BUILD_OPENINGS"] else {
            throw XCTSkip("set TEST_RUNNER_BLUNDERBOOK_BUILD_OPENINGS to build the bundled openings")
        }
        let levels = (environment["BLUNDERBOOK_LEVELS"] ?? "quick,standard").split(separator: ",")
            .compactMap { ReviewDepth(rawValue: String($0)) }

        // Every position of every named line, up to the cached depth, by its exact moves.
        let list = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "Openings", withExtension: "tsv")),
                              encoding: .utf8)
        var positions: [String: ChessBoard] = [:]
        for line in list.split(separator: "\n").dropFirst() {
            guard let pgn = line.split(separator: "\t").last else { continue }
            let moves = PGNParser.parse("[Event \"o\"]\n\n" + pgn).moves
            let board = try XCTUnwrap(ChessBoard(fen: ChessBoard.startFEN))
            positions[""] = board.copy()
            for (index, move) in moves.prefix(PositionCache.maxPly).enumerated() {
                board.makeMove(move)
                positions[PositionCache.key(moves.prefix(index + 1))] = board.copy()
            }
        }
        let keys = positions.keys.sorted()

        let count = max(1, (ThermalPacing.performanceEngineCount + ThermalPacing.efficiencyEngineCount) / 2)
        let analyzers: [GameAnalyzer] = try (0..<count).map { _ in
            let engine = try XCTUnwrap(StockfishEngine())
            engine.setWorkload(.bulkCool)
            return GameAnalyzer(engine: engine)
        }
        let signature = PositionCache.signature(of: try XCTUnwrap(StockfishEngine()))

        // What a previous run already wrote, for the same engine.
        var done = Set<String>()
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = existing.split(separator: "\n")
            guard lines.first == "#engine\t\(signature)"[...] else {
                return XCTFail("\(path) was built with another engine: move it away first")
            }
            for line in lines.dropFirst() {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                if fields.count == 7 { done.insert("\(fields[0])\t\(fields[1])") }
            }
        } else {
            try "#engine\t\(signature)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        let file = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        file.seekToEndOfFile()
        defer { try? file.close() }

        for level in levels {
            let nodes = level.nodesPerPosition
            let todo = keys.filter { !done.contains("\(nodes)\t\($0)") }
            let lock = NSLock()
            var next = 0
            var written = 0
            var failure: Error?
            let started = Date()
            DispatchQueue.concurrentPerform(iterations: analyzers.count) { slot in
                while true {
                    lock.lock()
                    guard failure == nil, next < todo.count else { lock.unlock(); return }
                    let key = todo[next]
                    next += 1
                    lock.unlock()
                    do {
                        let entry = CachedEvaluation(try analyzers[slot].search(positions[key]!, nodes: nodes))
                        let line = [String(nodes), key, entry.score.storageText, entry.bestMoveUCI ?? "",
                                    entry.lineUCI.joined(separator: " "), String(entry.depth), String(entry.nodes)]
                            .joined(separator: "\t") + "\n"
                        lock.lock()
                        file.write(Data(line.utf8))
                        written += 1
                        if written % 250 == 0 || written == todo.count {
                            print("BUILD|\(level.rawValue) \(written)/\(todo.count) \(Int(Date().timeIntervalSince(started)))s")
                        }
                        lock.unlock()
                    } catch {
                        lock.lock()
                        failure = error
                        lock.unlock()
                    }
                }
            }
            if let failure { throw failure }
        }
    }
}
