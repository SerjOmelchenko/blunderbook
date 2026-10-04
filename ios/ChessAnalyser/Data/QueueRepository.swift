//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

struct QueueCounts: Hashable {
    var pending = 0
    var running = 0
    var completed = 0
    var failed = 0
    var total: Int { pending + running + completed + failed }
    var finished: Int { completed + failed }
    var isEmpty: Bool { total == 0 }
    var isFinished: Bool { pending == 0 && running == 0 && total > 0 }
    var fraction: Double { total > 0 ? Double(finished) / Double(total) : 0 }
}

/// Durable analysis queue. Items survive process termination: an interrupted item goes back to
/// `pending` and its game is analysed again from the start; a game is analysed as one unit.
final class QueueRepository {
    static let manualPriority = 0
    static let bulkPriority = 100

    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    // MARK: - Batches

    /// Each entry carries the allowance pot that paid for it, so cancelling refunds correctly.
    @discardableResult
    func createBatch(playerID: UUID,
                     label: String,
                     entries: [(gameKey: String, bucket: AllowanceBucket)]) throws -> QueueBatch {
        let batch = QueueBatch(playerID: playerID, createdAt: Date(), isCancelled: false,
                               totalItems: entries.count, label: label)
        try database.transaction {
            try database.runUnsafe("""
                INSERT INTO queue_batches (id, player_id, created_at, cancelled, total_items, label)
                VALUES (?, ?, ?, 0, ?, ?);
                """, [batch.id.sqlValue, playerID.sqlValue, batch.createdAt.sqlValue,
                      entries.count.sqlValue, label.sqlValue])
            for entry in entries {
                // The unique index on active jobs makes duplicate enqueues a no-op (§7).
                try database.runUnsafe("""
                    INSERT OR IGNORE INTO queue_items (id, batch_id, player_id, charged_bucket,
                                                       game_key, policy_id, priority, state,
                                                       checkpoint_ply, attempts, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 0, ?);
                    """, [UUID().sqlValue, batch.id.sqlValue, playerID.sqlValue,
                          entry.bucket.rawValue.sqlValue, entry.gameKey.sqlValue,
                          AnalysisPolicy.identifier.sqlValue, Self.bulkPriority.sqlValue,
                          Date().sqlValue])
            }
        }
        return batch
    }

    /// Enqueues a single game ahead of any bulk work. Used by "Analyse this game".
    @discardableResult
    func enqueueManual(playerID: UUID, gameKey: String, bucket: AllowanceBucket) throws -> UUID {
        try database.transaction {
            if let existing = try database.queryUnsafe("""
                SELECT id AS value FROM queue_items
                WHERE game_key = ? AND policy_id = ? AND state IN ('pending', 'running');
                """, [gameKey.sqlValue, AnalysisPolicy.identifier.sqlValue]).first?.uuid("value") {
                try database.runUnsafe("UPDATE queue_items SET priority = ? WHERE id = ?;",
                                       [Self.manualPriority.sqlValue, existing.sqlValue])
                return existing
            }
            let batch = QueueBatch(playerID: playerID, createdAt: Date(), isCancelled: false,
                                   totalItems: 1, label: "Single review")
            try database.runUnsafe("""
                INSERT INTO queue_batches (id, player_id, created_at, cancelled, total_items, label)
                VALUES (?, ?, ?, 0, 1, ?);
                """, [batch.id.sqlValue, playerID.sqlValue, batch.createdAt.sqlValue, batch.label.sqlValue])
            let itemID = UUID()
            try database.runUnsafe("""
                INSERT INTO queue_items (id, batch_id, player_id, charged_bucket, game_key,
                                         policy_id, priority, state, checkpoint_ply, attempts,
                                         created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 0, ?);
                """, [itemID.sqlValue, batch.id.sqlValue, playerID.sqlValue,
                      bucket.rawValue.sqlValue, gameKey.sqlValue,
                      AnalysisPolicy.identifier.sqlValue, Self.manualPriority.sqlValue,
                      Date().sqlValue])
            return itemID
        }
    }

    /// Work that has not finished, so its allowance can be refunded before it is discarded.
    func unfinishedItems() throws -> [QueueItem] {
        try database.query("SELECT * FROM queue_items WHERE state IN ('pending', 'running');")
            .compactMap(Self.item)
    }

    /// Removes pending work and marks the batch cancelled. Completed reviews are kept (§7).
    func cancelAll() throws {
        try database.transaction {
            try database.runUnsafe("DELETE FROM queue_items WHERE state IN ('pending', 'running');")
            try database.runUnsafe("UPDATE queue_batches SET cancelled = 1;")
        }
    }

    func clearFinished() throws {
        try database.run("DELETE FROM queue_items WHERE state IN ('completed', 'failed');")
        try database.run("DELETE FROM queue_batches WHERE id NOT IN (SELECT batch_id FROM queue_items);")
    }

    // MARK: - Items

    /// Takes the next item and marks it running in one transaction, so two engines never take
    /// the same game. FIFO across players, newest game first inside a batch, manual work ahead of
    /// bulk (§7).
    ///
    /// - Parameters:
    ///   - manual: whether this engine may take reviews the person asked for.
    ///   - bulk: whether it may take bulk work. Bulk items it may not take stay pending (§3).
    func claimNextPendingItem(manual: Bool, bulk: Bool) throws -> QueueItem? {
        guard manual || bulk else { return nil }
        var filter = ""
        if !manual { filter += " AND i.priority > \(Self.manualPriority)" }
        if !bulk { filter += " AND i.priority <= \(Self.manualPriority)" }
        return try database.transaction {
            guard let row = try database.queryUnsafe("""
                SELECT i.* FROM queue_items i
                JOIN queue_batches b ON b.id = i.batch_id
                JOIN games g ON g.game_key = i.game_key
                WHERE i.state = 'pending' AND b.cancelled = 0\(filter)
                ORDER BY i.priority ASC, b.created_at ASC, g.end_time DESC
                LIMIT 1;
                """).first, var item = Self.item(row) else { return nil }
            try database.runUnsafe("UPDATE queue_items SET state = 'running' WHERE id = ?;", [item.id.sqlValue])
            item.state = .running
            return item
        }
    }

    func item(id: UUID) throws -> QueueItem? {
        try database.queryOne("SELECT * FROM queue_items WHERE id = ?;", [id.sqlValue]).flatMap(Self.item)
    }

    func activeItem(gameKey: String) throws -> QueueItem? {
        try database.queryOne("""
            SELECT * FROM queue_items WHERE game_key = ? AND state IN ('pending', 'running')
            ORDER BY priority ASC LIMIT 1;
            """, [gameKey.sqlValue]).flatMap(Self.item)
    }

    func setState(_ state: QueueItemState, id: UUID, checkpointPly: Int? = nil, error: String? = nil) throws {
        var sql = "UPDATE queue_items SET state = ?"
        var parameters: [SQLValue] = [state.rawValue.sqlValue]
        if let checkpointPly { sql += ", checkpoint_ply = ?"; parameters.append(checkpointPly.sqlValue) }
        if let error { sql += ", error = ?, attempts = attempts + 1"; parameters.append(error.sqlValue) }
        sql += " WHERE id = ?;"
        parameters.append(id.sqlValue)
        try database.run(sql, parameters)
    }

    /// Anything left `running` when the process stopped goes back to `pending`.
    func recoverInterruptedItems() throws {
        try database.run("UPDATE queue_items SET state = 'pending' WHERE state = 'running';")
    }

    /// Work queued under an older policy is analysed under the current one. Old checkpoints mean
    /// nothing now that a game is never resumed half way.
    func adoptCurrentPolicy() throws {
        try database.run("""
            UPDATE OR IGNORE queue_items SET policy_id = ?, checkpoint_ply = 0
            WHERE state IN ('pending', 'running') AND policy_id != ?;
            """, [AnalysisPolicy.identifier.sqlValue, AnalysisPolicy.identifier.sqlValue])
    }

    /// Marks a job as no longer holding a credit, after a refund.
    func clearChargedBucket(id: UUID) throws {
        try database.run("UPDATE queue_items SET charged_bucket = 'none' WHERE id = ?;", [id.sqlValue])
    }

    func retryFailed() throws {
        try database.run("UPDATE queue_items SET state = 'pending', error = NULL WHERE state = 'failed';")
    }

    func counts() throws -> QueueCounts {
        var counts = QueueCounts()
        for row in try database.query("SELECT state, COUNT(*) AS value FROM queue_items GROUP BY state;") {
            let value = row.int("value") ?? 0
            switch QueueItemState(rawValue: row.string("state") ?? "") {
            case .pending: counts.pending = value
            case .running: counts.running = value
            case .completed: counts.completed = value
            case .failed: counts.failed = value
            case .none: break
            }
        }
        return counts
    }

    func failedItems(limit: Int = 50) throws -> [QueueItem] {
        try database.query("SELECT * FROM queue_items WHERE state = 'failed' ORDER BY created_at DESC LIMIT ?;",
                           [limit.sqlValue]).compactMap(Self.item)
    }

    func pendingKeys(limit: Int = 500) throws -> [String] {
        try database.query("SELECT game_key AS value FROM queue_items WHERE state = 'pending' LIMIT ?;",
                           [limit.sqlValue]).compactMap { $0.string("value") }
    }

    /// Total plies still queued, used for the active-processing-time estimate.
    func pendingPlyEstimate() throws -> Int {
        try database.queryOne("""
            SELECT COALESCE(SUM(g.ply_count - i.checkpoint_ply), 0) AS value
            FROM queue_items i JOIN games g ON g.game_key = i.game_key
            WHERE i.state = 'pending';
            """)?.int("value") ?? 0
    }

    func hasPendingBulkWork() throws -> Bool {
        let count = try database.queryOne("""
            SELECT COUNT(*) AS value FROM queue_items WHERE state = 'pending' AND priority > ?;
            """, [Self.manualPriority.sqlValue])?.int("value") ?? 0
        return count > 0
    }

    // MARK: - Timing samples

    /// Device timing samples power the ETA. They are never imported from a backup, because they
    /// describe this device (§7).
    func recordTiming(plies: Int, seconds: Double) throws {
        guard plies > 0, seconds > 0 else { return }
        try database.run("INSERT INTO timing_samples (recorded_at, plies, seconds) VALUES (?, ?, ?);",
                         [Date().sqlValue, plies.sqlValue, seconds.sqlValue])
        try database.run("""
            DELETE FROM timing_samples WHERE id NOT IN (
                SELECT id FROM timing_samples ORDER BY recorded_at DESC LIMIT 25
            );
            """)
    }

    /// Median seconds per analysed ply, or nil while still sampling.
    func medianSecondsPerPly(minimumSamples: Int = 3) throws -> Double? {
        let rows = try database.query("SELECT plies, seconds FROM timing_samples ORDER BY recorded_at DESC LIMIT 25;")
        let rates = rows.compactMap { row -> Double? in
            guard let plies = row.int("plies"), plies > 0, let seconds = row.double("seconds") else { return nil }
            return seconds / Double(plies)
        }.sorted()
        guard rates.count >= minimumSamples else { return nil }
        return rates[rates.count / 2]
    }

    func timingSampleCount() throws -> Int {
        try database.queryOne("SELECT COUNT(*) AS value FROM timing_samples;")?.int("value") ?? 0
    }

    private static func item(_ row: SQLRow) -> QueueItem? {
        guard let id = row.uuid("id"), let batchID = row.uuid("batch_id"), let gameKey = row.string("game_key") else { return nil }
        return QueueItem(id: id,
                         batchID: batchID,
                         playerID: row.uuid("player_id"),
                         chargedBucket: AllowanceBucket(rawValue: row.string("charged_bucket") ?? "none") ?? .none,
                         gameKey: gameKey,
                         policyID: row.string("policy_id") ?? AnalysisPolicy.identifier,
                         priority: row.int("priority") ?? bulkPriority,
                         state: QueueItemState(rawValue: row.string("state") ?? "pending") ?? .pending,
                         checkpointPly: row.int("checkpoint_ply") ?? 0,
                         attempts: row.int("attempts") ?? 0,
                         errorMessage: row.string("error"),
                         createdAt: row.date("created_at") ?? Date())
    }
}

/// Small key/value store for the selected player, tab, filters and schema version.
final class PreferencesRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    func string(_ key: String) -> String? {
        ((try? database.queryOne("SELECT value FROM preferences WHERE key = ?;", [key.sqlValue])) ?? nil)?
            .string("value")
    }

    func set(_ key: String, _ value: String?) {
        guard let value else {
            _ = try? database.run("DELETE FROM preferences WHERE key = ?;", [key.sqlValue])
            return
        }
        _ = try? database.run("""
            INSERT INTO preferences (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, [key.sqlValue, value.sqlValue])
    }

    func value<T: Codable>(_ key: String, as type: T.Type) -> T? {
        guard let text = string(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setValue<T: Codable>(_ key: String, _ value: T?) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            set(key, nil)
            return
        }
        set(key, String(data: data, encoding: .utf8))
    }
}

enum PreferenceKey {
    static let selectedPlayer = "selected_player"
    static let selectedTab = "selected_tab"
    static let filters = "filters"
    static let queuePaused = "queue_paused"
    static let boardFlipped = "board_flipped"
    static let entitlementValidThrough = "entitlement_valid_through"
    static let lastSeenVersion = "last_seen_version"
}
