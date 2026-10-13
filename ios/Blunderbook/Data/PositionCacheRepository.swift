//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The searches of early positions this device has made, for `PositionCache`.
final class PositionCacheRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    /// The cached searches among `keys`, by key.
    func evaluations(engine: String, nodes: Int, keys: [String]) throws -> [String: CachedEvaluation] {
        guard !keys.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let rows = try database.query("""
            SELECT moves, score, best_move, line, depth, searched_nodes FROM position_cache
            WHERE engine = ? AND nodes = ? AND moves IN (\(placeholders));
            """, [engine.sqlValue, nodes.sqlValue] + keys.map(\.sqlValue))
        var result: [String: CachedEvaluation] = [:]
        for row in rows {
            guard let moves = row.string("moves"), let score = row.string("score"),
                  let depth = row.int("depth"), let searched = row.int("searched_nodes") else { continue }
            result[moves] = CachedEvaluation(score: .fromStorage(score),
                                             bestMoveUCI: row.string("best_move"),
                                             lineUCI: (row.string("line") ?? "").split(separator: " ").map(String.init),
                                             depth: depth,
                                             nodes: searched)
        }
        return result
    }

    /// Keeps the first search of each position; a later one is the same search.
    func store(engine: String, nodes: Int, entries: [(key: String, evaluation: CachedEvaluation)]) throws {
        guard !entries.isEmpty else { return }
        try database.transaction {
            for entry in entries {
                try database.runUnsafe("""
                    INSERT OR IGNORE INTO position_cache
                        (engine, nodes, moves, score, best_move, line, depth, searched_nodes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """, [engine.sqlValue, nodes.sqlValue, entry.key.sqlValue,
                          entry.evaluation.score.storageText.sqlValue, entry.evaluation.bestMoveUCI.sqlValue,
                          entry.evaluation.lineUCI.joined(separator: " ").sqlValue,
                          entry.evaluation.depth.sqlValue, entry.evaluation.nodes.sqlValue])
            }
        }
    }
}
