//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
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
    var completedAt: Date?
    var errorMessage: String?
}

/// Saved reviews: Stockfish's evaluations of a game's positions, and for a deep review the labels
/// on each move.
///
/// A game has at most one review that counts: its complete analysis, preferring a deep review,
/// then the current policy. Older policies stored evaluations of the same positions, searched at
/// least as deep, so a complete older review is shown rather than discarded; a new complete
/// analysis replaces it, except that a standard analysis never replaces a deep review.
final class AnalysisRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    /// Complete reviews first, then a deep review, then the current policy, then the newest.
    private static let preference = """
        ORDER BY (status = 'complete') DESC, (policy_id = '\(DeepReview.identifier)') DESC,
                 (policy_id = ?) DESC, COALESCE(completed_at, created_at) DESC
        """

    // MARK: - Reading

    /// The review that counts for a game, or its latest attempt when none is complete.
    func header(gameKey: String) throws -> AnalysisHeader? {
        try database.queryOne("SELECT * FROM analyses WHERE game_key = ? " + Self.preference + " LIMIT 1;",
                              [gameKey.sqlValue, AnalysisPolicy.identifier.sqlValue]).flatMap(Self.header)
    }

    /// The latest attempt under one policy, complete or not.
    func header(gameKey: String, policyID: String) throws -> AnalysisHeader? {
        try database.queryOne("""
            SELECT * FROM analyses WHERE game_key = ? AND policy_id = ?
            ORDER BY COALESCE(completed_at, created_at) DESC LIMIT 1;
            """, [gameKey.sqlValue, policyID.sqlValue]).flatMap(Self.header)
    }

    func analysis(gameKey: String) throws -> GameAnalysis? {
        guard let row = try database.queryOne("SELECT * FROM analyses WHERE game_key = ? " + Self.preference + " LIMIT 1;",
                                              [gameKey.sqlValue, AnalysisPolicy.identifier.sqlValue]),
              let id = row.uuid("id") else { return nil }

        return GameAnalysis(id: id,
                            gameKey: gameKey,
                            provenance: AnalysisProvenance(policyID: row.string("policy_id") ?? "",
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
                            moves: try moves(analysisID: id))
    }

    func moves(analysisID: UUID) throws -> [MoveAnalysis] {
        try database.query("""
            SELECT e.*, l.ply AS l_ply, l.best_move_san, l.best_line_san, l.best_line_uci, l.confirmed,
                   l.loss, l.accuracy, l.severity, l.phase, l.tags, l.consequence, l.explanation, l.is_best
            FROM move_evaluations e
            LEFT JOIN move_labels l ON l.analysis_id = e.analysis_id AND l.ply = e.ply
            WHERE e.analysis_id = ? ORDER BY e.ply ASC;
            """, [analysisID.sqlValue]).compactMap { row in
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
                                lineSAN: Self.split(row.string("line_san")),
                                lineUCI: Self.split(row.string("line_uci")),
                                depth: row.int("depth") ?? 0,
                                nodes: row.int("nodes") ?? 0,
                                labels: row.int("l_ply") == nil ? nil : Self.labels(row))
        }
    }

    private static func labels(_ row: SQLRow) -> MoveLabels {
        MoveLabels(bestMoveSAN: row.string("best_move_san"),
                   bestLineSAN: split(row.string("best_line_san")),
                   bestLineUCI: split(row.string("best_line_uci")),
                   confirmed: row.bool("confirmed"),
                   loss: row.double("loss") ?? 0,
                   accuracy: row.double("accuracy") ?? 0,
                   severity: row.string("severity").flatMap(Severity.init(rawValue:)),
                   phase: GamePhase(rawValue: row.string("phase") ?? "middlegame") ?? .middlegame,
                   tags: split(row.string("tags")).compactMap(PatternTag.init(rawValue:)),
                   consequence: Consequence(rawValue: row.string("consequence") ?? "") ?? .evaluationLoss,
                   explanation: row.string("explanation") ?? "",
                   isBest: row.bool("is_best"))
    }

    // MARK: - Writing

    /// Saves an analysis in one transaction. A complete one replaces every earlier review of the
    /// game; a failure leaves the previous review untouched, which keeps replacement atomic (§5).
    /// A standard analysis that finishes after the game was deep-reviewed is dropped: the deep
    /// review holds the same evaluations and more.
    func save(_ analysis: GameAnalysis) throws {
        try database.transaction {
            if !analysis.isDeep, try database.queryUnsafe("""
                SELECT 1 AS value FROM analyses WHERE game_key = ? AND policy_id = ? AND status = 'complete';
                """, [analysis.gameKey.sqlValue, DeepReview.identifier.sqlValue]).first != nil {
                return
            }
            if analysis.status == .complete {
                try database.runUnsafe("DELETE FROM analyses WHERE game_key = ? AND id != ?;",
                                       [analysis.gameKey.sqlValue, analysis.id.sqlValue])
            } else {
                try database.runUnsafe("DELETE FROM analyses WHERE game_key = ? AND policy_id = ? AND id != ?;",
                                       [analysis.gameKey.sqlValue, analysis.provenance.policyID.sqlValue,
                                        analysis.id.sqlValue])
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

            try database.runUnsafe("DELETE FROM move_evaluations WHERE analysis_id = ?;", [analysis.id.sqlValue])
            try database.runUnsafe("DELETE FROM move_labels WHERE analysis_id = ?;", [analysis.id.sqlValue])
            for move in analysis.moves {
                try database.runUnsafe("""
                    INSERT INTO move_evaluations (analysis_id, ply, mover, san, uci, fen_before, score_before,
                                                  score_after, line_san, line_uci, depth, nodes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [
                        analysis.id.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue,
                        move.san.sqlValue, move.uci.sqlValue, move.fenBefore.sqlValue,
                        move.scoreBefore.storageText.sqlValue, move.scoreAfter.storageText.sqlValue,
                        move.lineSAN.joined(separator: " ").sqlValue,
                        move.lineUCI.joined(separator: " ").sqlValue,
                        move.depth.sqlValue, move.nodes.sqlValue
                    ])
                if let labels = move.labels {
                    try database.runUnsafe("""
                        INSERT INTO move_labels (analysis_id, ply, mover, best_move_san, best_line_san, best_line_uci,
                                                 confirmed, loss, accuracy, severity, phase, tags, consequence,
                                                 explanation, is_best)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """, [
                            analysis.id.sqlValue, move.ply.sqlValue, move.mover.rawValue.sqlValue,
                            labels.bestMoveSAN.sqlValue,
                            labels.bestLineSAN.joined(separator: " ").sqlValue,
                            labels.bestLineUCI.joined(separator: " ").sqlValue,
                            labels.confirmed.sqlValue, labels.loss.sqlValue, labels.accuracy.sqlValue,
                            labels.severity?.rawValue.sqlValue ?? .null,
                            labels.phase.rawValue.sqlValue,
                            labels.tags.map(\.rawValue).joined(separator: " ").sqlValue,
                            labels.consequence.rawValue.sqlValue,
                            labels.explanation.sqlValue, labels.isBest.sqlValue
                        ])
                }
            }
        }
    }

    // MARK: - Re-tagging

    /// Runs the current pattern detectors again over every deep review tagged by an older
    /// version, from the positions and engine lines it already stores: no search is repeated,
    /// and evaluations, losses and severities stay exactly as they were. Returns how many
    /// reviews were re-tagged.
    @discardableResult
    func retagDeepReviews() throws -> Int {
        let ids = try database.query("""
            SELECT id FROM analyses WHERE policy_id = ? AND status = 'complete' AND tagger_version != ?;
            """, [DeepReview.identifier.sqlValue, DeepReview.taggerIdentifier.sqlValue]).compactMap { $0.uuid("id") }
        for id in ids {
            let updates = try moves(analysisID: id).compactMap { move in
                move.labels.flatMap { labels in Self.redetect(move, labels: labels).map { (move.ply, $0) } }
            }
            try database.transaction {
                for (ply, detection) in updates {
                    try database.runUnsafe("""
                        UPDATE move_labels SET tags = ?, consequence = ?, explanation = ?
                        WHERE analysis_id = ? AND ply = ?;
                        """, [detection.tags.map(\.rawValue).joined(separator: " ").sqlValue,
                              detection.consequence.rawValue.sqlValue, detection.explanation.sqlValue,
                              id.sqlValue, ply.sqlValue])
                }
                try database.runUnsafe("UPDATE analyses SET tagger_version = ? WHERE id = ?;",
                                       [DeepReview.taggerIdentifier.sqlValue, id.sqlValue])
            }
        }
        return ids.count
    }

    /// Brings deep reviews scored by an older scoring version up to the current one, from the
    /// losses and evaluations they already store: no search is repeated, and evaluations,
    /// losses and severities stay exactly as they were. Returns how many reviews were rescored.
    @discardableResult
    func rescoreDeepReviews() throws -> Int {
        let ids = try database.query("""
            SELECT id FROM analyses WHERE policy_id = ? AND status = 'complete' AND scoring_version != ?;
            """, [DeepReview.identifier.sqlValue, DeepReview.scoringIdentifier.sqlValue]).compactMap { $0.uuid("id") }
        for id in ids {
            let moves = try moves(analysisID: id).map { move in
                var move = move
                if let loss = move.labels?.loss { move.labels?.accuracy = Scoring.moveAccuracy(loss: loss) }
                return move
            }
            let accuracies = Scoring.gameAccuracies(moves)
            try database.transaction {
                for move in moves {
                    guard let labels = move.labels else { continue }
                    try database.runUnsafe("UPDATE move_labels SET accuracy = ? WHERE analysis_id = ? AND ply = ?;",
                                           [labels.accuracy.sqlValue, id.sqlValue, move.ply.sqlValue])
                }
                try database.runUnsafe("""
                    UPDATE analyses SET white_accuracy = ?, black_accuracy = ?, scoring_version = ? WHERE id = ?;
                    """, [accuracies.white.sqlValue, accuracies.black.sqlValue,
                          DeepReview.scoringIdentifier.sqlValue, id.sqlValue])
            }
        }
        return ids.count
    }

    /// The detection a deep review would make today for a stored move, rebuilt exactly as
    /// `GameAnalyzer` builds it. Nil when the stored position or move cannot be replayed.
    private static func redetect(_ move: MoveAnalysis, labels: MoveLabels) -> DetectionResult? {
        guard let before = ChessBoard(fen: move.fenBefore), let played = Move.fromUCI(move.uci),
              before.isLegalMove(played) else { return nil }
        let after = before.copy()
        after.makeMove(played)
        let bestLine = labels.bestLineUCI.compactMap(Move.fromUCI)
        return PatternDetectors.detect(DetectionContext(boardBefore: before,
                                                        playedMove: played,
                                                        boardAfter: after,
                                                        bestMove: labels.isBest ? nil : bestLine.first,
                                                        bestLine: bestLine,
                                                        replyLine: move.lineUCI.compactMap(Move.fromUCI),
                                                        mover: move.mover,
                                                        scoreBefore: move.scoreBefore.fromWhite(to: move.mover),
                                                        scoreAfter: move.scoreAfter.fromWhite(to: move.mover),
                                                        loss: labels.loss,
                                                        isBest: labels.isBest))
    }

    /// Records a failed attempt under a policy. Any complete review of the game stays.
    func markFailed(gameKey: String, message: String, policyID: String = AnalysisPolicy.identifier) throws {
        var provenance = AnalysisPolicy.activeProvenance
        if DeepReview.isDeep(policyID: policyID) {
            provenance.policyID = DeepReview.identifier
            provenance.scoringVersion = DeepReview.scoringIdentifier
            provenance.taggerVersion = DeepReview.taggerIdentifier
        }
        if let existing = try database.queryOne("SELECT id AS value FROM analyses WHERE game_key = ? AND policy_id = ?;",
                                                [gameKey.sqlValue, provenance.policyID.sqlValue])?.string("value") {
            try database.run("UPDATE analyses SET status = 'failed', error = ? WHERE id = ?;",
                             [message.sqlValue, existing.sqlValue])
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
    static let reviewTables = ["analyses", "move_evaluations", "move_labels"]

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

    /// The games among `keys`, in their order, with no complete review under any policy.
    /// Queried in chunks, because SQLite caps the number of bound parameters; checking only the
    /// first chunk would re-queue every reviewed game beyond it.
    func withoutDeepReview(_ keys: [String]) throws -> [String] {
        let chunkSize = 900
        var reviewed = Set<String>()
        for start in stride(from: 0, to: keys.count, by: chunkSize) {
            let slice = keys[start..<min(start + chunkSize, keys.count)]
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = try database.query("""
                SELECT DISTINCT game_key AS value FROM analyses
                WHERE status = 'complete' AND policy_id = ? AND game_key IN (\(placeholders));
                """, [DeepReview.identifier.sqlValue] + slice.map { $0.sqlValue })
            reviewed.formUnion(rows.compactMap { $0.string("value") })
        }
        return keys.filter { !reviewed.contains($0) }
    }

    /// Games with a complete review, under any policy.
    func completedCount() throws -> Int {
        try database.queryOne("SELECT COUNT(DISTINCT game_key) AS value FROM analyses WHERE status = 'complete';")?
            .int("value") ?? 0
    }

    private static func header(_ row: SQLRow) -> AnalysisHeader? {
        guard let id = row.uuid("id"), let gameKey = row.string("game_key") else { return nil }
        return AnalysisHeader(id: id,
                              gameKey: gameKey,
                              policyID: row.string("policy_id") ?? "",
                              status: AnalysisStatus(rawValue: row.string("status") ?? "pending") ?? .pending,
                              nextPly: row.int("next_ply") ?? 0,
                              completedAt: row.date("completed_at"),
                              errorMessage: row.string("error"))
    }

    private static func split(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: " ").map(String.init)
    }
}
