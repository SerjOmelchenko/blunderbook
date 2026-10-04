//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Lightweight header used wherever the full move list is not needed.
struct AnalysisHeader: Hashable {
    var id: UUID
    var gameKey: String
    var policyID: String
    var status: AnalysisStatus
    var nextPly: Int
    var whiteAccuracy: Double?
    var blackAccuracy: Double?
    var completedAt: Date?
    var errorMessage: String?
    var isCurrentPolicy: Bool { policyID == AnalysisPolicy.identifier }
}

final class AnalysisRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    // MARK: - Reading

    func header(gameKey: String, policyID: String = AnalysisPolicy.identifier) throws -> AnalysisHeader? {
        try database.queryOne("SELECT * FROM analyses WHERE game_key = ? AND policy_id = ?;",
                              [gameKey.sqlValue, policyID.sqlValue]).flatMap(Self.header)
    }

    /// Every stored review for a game, current policy first. Older-policy reviews stay readable
    /// and simply carry their own provenance (§5).
    func headers(gameKey: String) throws -> [AnalysisHeader] {
        try database.query("SELECT * FROM analyses WHERE game_key = ? ORDER BY completed_at DESC;",
                           [gameKey.sqlValue]).compactMap(Self.header)
    }

    func analysis(gameKey: String, policyID: String = AnalysisPolicy.identifier) throws -> GameAnalysis? {
        guard let row = try database.queryOne("SELECT * FROM analyses WHERE game_key = ? AND policy_id = ?;",
                                              [gameKey.sqlValue, policyID.sqlValue]),
              let id = row.uuid("id") else { return nil }

        let moves = try self.moves(analysisID: id)
        return GameAnalysis(id: id,
                            gameKey: gameKey,
                            provenance: AnalysisProvenance(policyID: row.string("policy_id") ?? policyID,
                                                           engineVersion: row.string("engine_version") ?? "",
                                                           evaluationVersion: row.string("evaluation_version") ?? "",
                                                           scoringVersion: row.string("scoring_version") ?? "",
                                                           taggerVersion: row.string("tagger_version") ?? ""),
                            status: AnalysisStatus(rawValue: row.string("status") ?? "pending") ?? .pending,
                            nextPly: row.int("next_ply") ?? 0,
                            whiteAccuracy: row.double("white_accuracy"),
                            blackAccuracy: row.double("black_accuracy"),
                            createdAt: row.date("created_at") ?? Date(),
                            completedAt: row.date("completed_at"),
                            errorMessage: row.string("error"),
                            moves: moves)
    }

    func moves(analysisID: UUID) throws -> [MoveAnalysis] {
        let tagRows = try database.query("SELECT ply, tag FROM move_tags WHERE analysis_id = ?;", [analysisID.sqlValue])
        var tagsByPly: [Int: [PatternTag]] = [:]
        for row in tagRows {
            guard let ply = row.int("ply"), let tag = row.string("tag").flatMap(PatternTag.init(rawValue:)) else { continue }
            tagsByPly[ply, default: []].append(tag)
        }
        return try database.query("SELECT * FROM move_analyses WHERE analysis_id = ? ORDER BY ply ASC;",
                                  [analysisID.sqlValue]).compactMap { row in
            guard let ply = row.int("ply"),
                  let moverValue = row.int("mover"),
                  let mover = PieceColor(rawValue: moverValue) else { return nil }
            return MoveAnalysis(ply: ply,
                                mover: mover,
                                san: row.string("san") ?? "",
                                uci: row.string("uci") ?? "",
                                fenBefore: row.string("fen_before") ?? ChessBoard.startFEN,
                                scoreBefore: EngineScore.fromStorage(row.string("score_before") ?? ""),
                                scoreAfter: EngineScore.fromStorage(row.string("score_after") ?? ""),
                                bestMoveSAN: row.string("best_move_san"),
                                bestLineSAN: Self.split(row.string("best_line_san")),
                                bestLineUCI: Self.split(row.string("best_line_uci")),
                                replyLineSAN: Self.split(row.string("reply_line_san")),
                                replyLineUCI: Self.split(row.string("reply_line_uci")),
                                depth: row.int("depth") ?? 0,
                                nodes: row.int("nodes") ?? 0,
                                confirmed: row.bool("confirmed"),
                                loss: row.double("loss") ?? 0,
                                accuracy: row.double("accuracy") ?? 0,
                                severity: row.string("severity").flatMap(Severity.init(rawValue:)),
                                phase: GamePhase(rawValue: row.string("phase") ?? "middlegame") ?? .middlegame,
                                tags: tagsByPly[ply] ?? [],
                                consequence: Consequence(rawValue: row.string("consequence") ?? "") ?? .evaluationLoss,
                                explanation: row.string("explanation") ?? "",
                                isBest: row.bool("is_best"))
        }
    }

    // MARK: - Writing

    /// Replaces any analysis for the same game and policy in a single transaction. A failure
    /// leaves the previous review untouched, which is what makes replacement atomic (§5).
    func save(_ analysis: GameAnalysis) throws {
        try database.transaction {
            let existingID = try database.queryUnsafe(
                "SELECT id AS value FROM analyses WHERE game_key = ? AND policy_id = ?;",
                [analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue]
            ).first?.string("value")

            if let existingID, existingID != analysis.id.uuidString {
                try database.runUnsafe("DELETE FROM analyses WHERE id = ?;", [existingID.sqlValue])
            }

            try database.runUnsafe("""
                INSERT INTO analyses (id, game_key, policy_id, engine_version, evaluation_version, scoring_version,
                                      tagger_version, status, next_ply, white_accuracy, black_accuracy,
                                      created_at, completed_at, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    status = excluded.status, next_ply = excluded.next_ply,
                    white_accuracy = excluded.white_accuracy, black_accuracy = excluded.black_accuracy,
                    completed_at = excluded.completed_at, error = excluded.error;
                """, [
                    analysis.id.sqlValue, analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue,
                    analysis.provenance.engineVersion.sqlValue, analysis.provenance.evaluationVersion.sqlValue,
                    analysis.provenance.scoringVersion.sqlValue, analysis.provenance.taggerVersion.sqlValue,
                    analysis.status.rawValue.sqlValue, analysis.nextPly.sqlValue,
                    analysis.whiteAccuracy.sqlValue, analysis.blackAccuracy.sqlValue,
                    analysis.createdAt.sqlValue, analysis.completedAt.sqlValue, analysis.errorMessage.sqlValue
                ])

            try database.runUnsafe("DELETE FROM move_analyses WHERE analysis_id = ?;", [analysis.id.sqlValue])
            try database.runUnsafe("DELETE FROM move_tags WHERE analysis_id = ?;", [analysis.id.sqlValue])

            for move in analysis.moves {
                try database.runUnsafe("""
                    INSERT INTO move_analyses (analysis_id, ply, mover, san, uci, fen_before, score_before, score_after,
                                               best_move_san, best_line_san, best_line_uci, reply_line_san,
                                               reply_line_uci, depth, nodes, confirmed, loss, accuracy, severity,
                                               phase, consequence, explanation, is_best)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [
                        analysis.id.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue,
                        move.san.sqlValue, move.uci.sqlValue, move.fenBefore.sqlValue,
                        move.scoreBefore.storageText.sqlValue, move.scoreAfter.storageText.sqlValue,
                        move.bestMoveSAN.sqlValue,
                        move.bestLineSAN.joined(separator: " ").sqlValue,
                        move.bestLineUCI.joined(separator: " ").sqlValue,
                        move.replyLineSAN.joined(separator: " ").sqlValue,
                        move.replyLineUCI.joined(separator: " ").sqlValue,
                        move.depth.sqlValue, move.nodes.sqlValue, move.confirmed.sqlValue,
                        move.loss.sqlValue, move.accuracy.sqlValue,
                        move.severity?.rawValue.sqlValue ?? .null,
                        move.phase.rawValue.sqlValue, move.consequence.rawValue.sqlValue,
                        move.explanation.sqlValue, move.isBest.sqlValue
                    ])
                for tag in move.tags {
                    try database.runUnsafe("""
                        INSERT OR IGNORE INTO move_tags (analysis_id, ply, mover, tag) VALUES (?, ?, ?, ?);
                        """, [analysis.id.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue, tag.rawValue.sqlValue])
                }
            }

            try writeSummaries(analysis)
        }
    }

    /// Per-game, per-colour rollups. Analytics reads these instead of scanning every move row,
    /// which is what keeps a 50,000-game history responsive (§9).
    private func writeSummaries(_ analysis: GameAnalysis) throws {
        try database.runUnsafe("DELETE FROM analysis_summaries WHERE analysis_id = ?;", [analysis.id.sqlValue])
        try database.runUnsafe("DELETE FROM analysis_tag_summaries WHERE analysis_id = ?;", [analysis.id.sqlValue])
        guard analysis.status == .complete else { return }

        for color in PieceColor.allCases {
            let moves = analysis.moves(by: color)
            guard !moves.isEmpty else { continue }
            let errors = moves.filter(\.isError)
            func phaseCount(_ phase: GamePhase) -> Int { moves.filter { $0.phase == phase }.count }
            func phaseErrors(_ phase: GamePhase) -> Int { errors.filter { $0.phase == phase }.count }

            try database.runUnsafe("""
                INSERT INTO analysis_summaries (analysis_id, game_key, policy_id, color, moves, accuracy,
                                                inaccuracies, mistakes, blunders, opening_moves, middlegame_moves,
                                                endgame_moves, opening_errors, middlegame_errors, endgame_errors)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [
                    analysis.id.sqlValue, analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue,
                    color.rawValue.sqlValue, moves.count.sqlValue,
                    analysis.accuracy(for: color).sqlValue,
                    errors.filter { $0.severity == .inaccuracy }.count.sqlValue,
                    errors.filter { $0.severity == .mistake }.count.sqlValue,
                    errors.filter { $0.severity == .blunder }.count.sqlValue,
                    phaseCount(.opening).sqlValue, phaseCount(.middlegame).sqlValue, phaseCount(.endgame).sqlValue,
                    phaseErrors(.opening).sqlValue, phaseErrors(.middlegame).sqlValue, phaseErrors(.endgame).sqlValue
                ])

            var tagCounts: [PatternTag: Int] = [:]
            for move in errors {
                // A tag is counted once per move per category; overlapping categories are labelled
                // as such wherever the totals are shown (§6).
                for tag in Set(move.tags) { tagCounts[tag, default: 0] += 1 }
            }
            var rows = tagCounts.map { (key: $0.key.rawValue, count: $0.value) }
            // Errors the detectors could not explain are a category in their own right, not a
            // gap to be hidden (§6: Unknown pattern is a valid category).
            let unknown = errors.filter { $0.tags.isEmpty }.count
            if unknown > 0 { rows.append((key: MistakeCategory.unknownTagKey, count: unknown)) }
            for row in rows where row.count > 0 {
                try database.runUnsafe("""
                    INSERT INTO analysis_tag_summaries (analysis_id, game_key, policy_id, color, tag, count)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """, [analysis.id.sqlValue, analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue,
                          color.rawValue.sqlValue, row.key.sqlValue, row.count.sqlValue])
            }
        }
    }

    /// Persists one completed ply plus the resume point. Cheap enough to run after every ply,
    /// which is what lets an interruption lose no finished work (§7).
    func checkpoint(_ analysis: GameAnalysis, row: MoveAnalysis) throws {
        try database.transaction {
            try database.runUnsafe("""
                INSERT INTO analyses (id, game_key, policy_id, engine_version, evaluation_version, scoring_version,
                                      tagger_version, status, next_ply, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'running', ?, ?)
                ON CONFLICT(id) DO UPDATE SET status = 'running', next_ply = excluded.next_ply;
                """, [analysis.id.sqlValue, analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue,
                      analysis.provenance.engineVersion.sqlValue, analysis.provenance.evaluationVersion.sqlValue,
                      analysis.provenance.scoringVersion.sqlValue, analysis.provenance.taggerVersion.sqlValue,
                      analysis.nextPly.sqlValue, analysis.createdAt.sqlValue])
            try insertMove(analysisID: analysis.id, move: row)
        }
    }

    private func insertMove(analysisID: UUID, move: MoveAnalysis) throws {
        try database.runUnsafe("""
            INSERT OR REPLACE INTO move_analyses (analysis_id, ply, mover, san, uci, fen_before, score_before,
                                                  score_after, best_move_san, best_line_san, best_line_uci,
                                                  reply_line_san, reply_line_uci, depth, nodes, confirmed, loss,
                                                  accuracy, severity, phase, consequence, explanation, is_best)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                analysisID.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue,
                move.san.sqlValue, move.uci.sqlValue, move.fenBefore.sqlValue,
                move.scoreBefore.storageText.sqlValue, move.scoreAfter.storageText.sqlValue,
                move.bestMoveSAN.sqlValue,
                move.bestLineSAN.joined(separator: " ").sqlValue,
                move.bestLineUCI.joined(separator: " ").sqlValue,
                move.replyLineSAN.joined(separator: " ").sqlValue,
                move.replyLineUCI.joined(separator: " ").sqlValue,
                move.depth.sqlValue, move.nodes.sqlValue, move.confirmed.sqlValue,
                move.loss.sqlValue, move.accuracy.sqlValue,
                move.severity?.rawValue.sqlValue ?? .null,
                move.phase.rawValue.sqlValue, move.consequence.rawValue.sqlValue,
                move.explanation.sqlValue, move.isBest.sqlValue
            ])
        for tag in move.tags {
            try database.runUnsafe("""
                INSERT OR IGNORE INTO move_tags (analysis_id, ply, mover, tag) VALUES (?, ?, ?, ?);
                """, [analysisID.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue, tag.rawValue.sqlValue])
        }
    }

    func markFailed(gameKey: String, message: String) throws {
        let provenance = AnalysisPolicy.activeProvenance
        if let existing = try header(gameKey: gameKey) {
            try database.run("UPDATE analyses SET status = 'failed', error = ? WHERE id = ?;",
                             [message.sqlValue, existing.id.sqlValue])
        } else {
            try database.run("""
                INSERT INTO analyses (id, game_key, policy_id, engine_version, evaluation_version, scoring_version,
                                      tagger_version, status, next_ply, created_at, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'failed', 0, ?, ?);
                """, [UUID().sqlValue, gameKey.sqlValue, provenance.policyID.sqlValue,
                      provenance.engineVersion.sqlValue, provenance.evaluationVersion.sqlValue,
                      provenance.scoringVersion.sqlValue, provenance.taggerVersion.sqlValue,
                      Date().sqlValue, message.sqlValue])
        }
    }

    func delete(gameKey: String) throws {
        try database.run("DELETE FROM analyses WHERE game_key = ?;", [gameKey.sqlValue])
    }

    /// Clears reviews for one player's games while leaving games — and any other tracked
    /// player's shared reviews — untouched (§10).
    @discardableResult
    func deleteAnalyses(playerID: UUID) throws -> Int {
        try database.run("""
            DELETE FROM analyses WHERE game_key IN (
                SELECT game_key FROM player_games WHERE player_id = ?
            ) AND game_key NOT IN (
                SELECT game_key FROM player_games WHERE player_id != ?
            );
            """, [playerID.sqlValue, playerID.sqlValue])
    }

    /// Tables that hold saved reviews and nothing else.
    static let reviewTables = ["analyses", "move_analyses", "move_tags",
                               "analysis_summaries", "analysis_tag_summaries"]

    /// Bytes of saved review data, indexes included. Counts payload rather than pages, so an
    /// empty store reports zero rather than the fixed cost of its empty tables.
    func storageBytes() throws -> Int64 {
        let names = Self.reviewTables.map { "'\($0)'" }.joined(separator: ",")
        if let row = try? database.queryOne("""
            SELECT COALESCE(SUM(d.payload), 0) AS value FROM dbstat d
            JOIN sqlite_master m ON m.name = d.name
            WHERE m.tbl_name IN (\(names));
            """), let value = row.int("value") {
            return Int64(value)
        }
        // Builds without the dbstat table: add up the stored values instead.
        var total: Int64 = 0
        for table in Self.reviewTables {
            let columns = try database.query("PRAGMA table_info(\(table));").compactMap { $0.string("name") }
            guard !columns.isEmpty else { continue }
            let sum = columns.map { "COALESCE(LENGTH(\($0)), 0)" }.joined(separator: " + ")
            total += Int64(try database.queryOne("SELECT COALESCE(SUM(\(sum)), 0) AS value FROM \(table);")?.int("value") ?? 0)
        }
        return total
    }

    func completedCount(policyID: String = AnalysisPolicy.identifier) throws -> Int {
        try database.queryOne("SELECT COUNT(*) AS value FROM analyses WHERE policy_id = ? AND status = 'complete';",
                              [policyID.sqlValue])?.int("value") ?? 0
    }

    private static func header(_ row: SQLRow) -> AnalysisHeader? {
        guard let id = row.uuid("id"), let gameKey = row.string("game_key") else { return nil }
        return AnalysisHeader(id: id,
                              gameKey: gameKey,
                              policyID: row.string("policy_id") ?? "",
                              status: AnalysisStatus(rawValue: row.string("status") ?? "pending") ?? .pending,
                              nextPly: row.int("next_ply") ?? 0,
                              whiteAccuracy: row.double("white_accuracy"),
                              blackAccuracy: row.double("black_accuracy"),
                              completedAt: row.date("completed_at"),
                              errorMessage: row.string("error"))
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: " ").map(String.init)
    }
}
