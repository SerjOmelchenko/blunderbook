//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

// MARK: - Score storage

extension EngineScore {
    /// Compact, stable text form used in SQLite and in backup NDJSON.
    var storageText: String {
        switch self {
        case .centipawns(let value): return "cp:\(value)"
        case .mate(let moves): return "m:\(moves)"
        case .checkmate(let won): return "cm:\(won ? 1 : 0)"
        }
    }

    static func fromStorage(_ text: String) -> EngineScore {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return .centipawns(0) }
        switch parts[0] {
        case "cp": return .centipawns(number)
        case "m": return .mate(number)
        case "cm": return .checkmate(perspectiveWon: number != 0)
        default: return .centipawns(0)
        }
    }
}

// MARK: - Players

/// Repositories own all SQL. Nothing above this layer builds a statement (§2).
final class PlayerRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    func all() throws -> [TrackedPlayer] {
        try database.query("SELECT * FROM players ORDER BY created_at ASC;").compactMap(Self.player)
    }

    func player(id: UUID) throws -> TrackedPlayer? {
        try database.queryOne("SELECT * FROM players WHERE id = ?;", [id.sqlValue]).flatMap(Self.player)
    }

    /// Usernames are only unique within one site: "hikaru" on Lichess is not "hikaru" on Chess.com.
    func player(username: String, provider: Provider) throws -> TrackedPlayer? {
        try database.queryOne("SELECT * FROM players WHERE provider = ? AND username = ?;",
                              [provider.rawValue.sqlValue, username.lowercased().sqlValue])
            .flatMap(Self.player)
    }

    func player(providerID: String) throws -> TrackedPlayer? {
        try database.queryOne("SELECT * FROM players WHERE provider_id = ?;", [providerID.sqlValue])
            .flatMap(Self.player)
    }

    func save(_ player: TrackedPlayer) throws {
        try database.run("""
            INSERT INTO players (id, provider, provider_id, username, display_username, aliases, avatar_url,
                                 country, title, last_checked, last_success, status, created_at, verified_window)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider_id = excluded.provider_id,
                username = excluded.username,
                display_username = excluded.display_username,
                aliases = excluded.aliases,
                avatar_url = excluded.avatar_url,
                country = excluded.country,
                title = excluded.title,
                last_checked = excluded.last_checked,
                last_success = excluded.last_success,
                status = excluded.status,
                verified_window = excluded.verified_window;
            """, [
                player.id.sqlValue,
                player.provider.rawValue.sqlValue,
                player.providerID.sqlValue,
                player.username.lowercased().sqlValue,
                player.displayUsername.sqlValue,
                player.aliases.joined(separator: ",").sqlValue,
                player.avatarURL.sqlValue,
                player.country.sqlValue,
                player.title.sqlValue,
                player.lastChecked.sqlValue,
                player.lastSuccessfulRefresh.sqlValue,
                player.status.rawValue.sqlValue,
                player.createdAt.sqlValue,
                player.hasVerifiedWindow.sqlValue
            ])
    }

    /// Removes the profile and its memberships, then deletes games and reviews that no remaining
    /// tracked player references (§10).
    func delete(id: UUID) throws {
        try database.transaction {
            try database.runUnsafe("DELETE FROM player_games WHERE player_id = ?;", [id.sqlValue])
            try database.runUnsafe("DELETE FROM players WHERE id = ?;", [id.sqlValue])
            try database.runUnsafe("""
                DELETE FROM games WHERE game_key NOT IN (SELECT game_key FROM player_games);
                """)
            // The cache holds the openings of their games: it goes with the last player.
            try database.runUnsafe("DELETE FROM position_cache WHERE NOT EXISTS (SELECT 1 FROM players);")
        }
    }

    static func player(_ row: SQLRow) -> TrackedPlayer? {
        guard let id = row.uuid("id"), let username = row.string("username") else { return nil }
        let aliases = (row.string("aliases") ?? "").split(separator: ",").map(String.init)
        return TrackedPlayer(id: id,
                             provider: Provider(rawValue: row.string("provider") ?? "") ?? .chessCom,
                             providerID: row.string("provider_id"),
                             username: username,
                             displayUsername: row.string("display_username") ?? username,
                             aliases: aliases,
                             avatarURL: row.string("avatar_url"),
                             country: row.string("country"),
                             title: row.string("title"),
                             lastChecked: row.date("last_checked"),
                             lastSuccessfulRefresh: row.date("last_success"),
                             status: PlayerSyncStatus(rawValue: row.string("status") ?? "never") ?? .never,
                             createdAt: row.date("created_at") ?? Date(),
                             hasVerifiedWindow: row.bool("verified_window"))
    }
}

// MARK: - Games

/// A row of the Games list: the game, this player's side, and the state of its review.
struct GameListEntry: Identifiable, Hashable {
    var game: GameRecord
    var color: PieceColor
    var outcome: GameOutcome
    var inFreeWindow: Bool
    var analysisStatus: AnalysisStatus?
    var analysisPolicyID: String? = nil
    /// This player's game accuracy; deep reviews only.
    var accuracy: Double? = nil
    /// The player's mean game accuracy over deep-reviewed games of the same time class in the 30
    /// days, and the 12 months, up to and including this game. Deep reviews only.
    var accuracy30Days: Double? = nil
    var accuracy12Months: Double? = nil
    /// The player's errors in this game's deep review, and how many of them are solved.
    var errorCount = 0
    var solvedCount = 0
    /// A review of the game is waiting in the queue or running.
    var isQueued = false

    var id: String { game.gameKey }
    var hasReview: Bool { analysisStatus == .complete }
    var hasDeepReview: Bool { hasReview && analysisPolicyID.map(DeepReview.isDeep(policyID:)) == true }
    /// Every error in the game is solved; a game without errors has nothing left to solve.
    var allMistakesSolved: Bool { solvedCount >= errorCount }
    var opponent: GameSide { game.opponent(of: color) }
    var player: GameSide { game.side(for: color) }
}

final class GameRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    // MARK: Writing

    /// Upsert by canonical key. A repeated import never duplicates a game, and a changed move
    /// sequence invalidates any analysis stored against the old content (§4).
    func upsert(_ games: [GameRecord]) throws {
        guard !games.isEmpty else { return }
        try database.transaction {
            for game in games {
                let previousHash = try database.queryUnsafe(
                    "SELECT move_hash AS value FROM games WHERE game_key = ?;", [game.gameKey.sqlValue]
                ).first?.string("value")

                try database.runUnsafe("""
                    INSERT INTO games (game_key, url, uuid, pgn, start_fen, move_hash, end_time, time_class,
                                       time_control, rules, rated, white_username, white_rating, white_result,
                                       black_username, black_rating, black_result, eco, eco_url, opening_name,
                                       parse_state, ply_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(game_key) DO UPDATE SET
                        url = excluded.url, uuid = excluded.uuid, pgn = excluded.pgn,
                        start_fen = excluded.start_fen, move_hash = excluded.move_hash,
                        end_time = excluded.end_time, time_class = excluded.time_class,
                        time_control = excluded.time_control, rules = excluded.rules, rated = excluded.rated,
                        white_username = excluded.white_username, white_rating = excluded.white_rating,
                        white_result = excluded.white_result, black_username = excluded.black_username,
                        black_rating = excluded.black_rating, black_result = excluded.black_result,
                        eco = excluded.eco, eco_url = excluded.eco_url, opening_name = excluded.opening_name,
                        parse_state = excluded.parse_state, ply_count = excluded.ply_count;
                    """, [
                        game.gameKey.sqlValue, game.url.sqlValue, game.uuid.sqlValue, game.pgn.sqlValue,
                        game.startFEN.sqlValue, game.moveHash.sqlValue, game.endTime.sqlValue,
                        game.timeClass.rawValue.sqlValue, game.timeControl.sqlValue, game.rules.sqlValue,
                        game.rated.sqlValue, game.white.username.sqlValue, game.white.rating.sqlValue,
                        game.white.resultCode.sqlValue, game.black.username.sqlValue, game.black.rating.sqlValue,
                        game.black.resultCode.sqlValue, game.eco.sqlValue, game.ecoURL.sqlValue,
                        game.openingName.sqlValue, game.parseState.rawValue.sqlValue, game.plyCount.sqlValue
                    ])

                if let previousHash, previousHash != game.moveHash {
                    try database.runUnsafe("DELETE FROM analyses WHERE game_key = ?;", [game.gameKey.sqlValue])
                }
            }
        }
    }

    func link(playerID: UUID, game: GameRecord, color: PieceColor) throws {
        let side = game.side(for: color)
        try database.run("""
            INSERT INTO player_games (player_id, game_key, color, outcome, in_window, window_version,
                                      end_time, time_class, rated, rating, opening_name)
            VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)
            ON CONFLICT(player_id, game_key) DO UPDATE SET
                color = excluded.color, outcome = excluded.outcome, end_time = excluded.end_time,
                time_class = excluded.time_class, rated = excluded.rated, rating = excluded.rating,
                opening_name = excluded.opening_name;
            """, [
                playerID.sqlValue, game.gameKey.sqlValue, color.rawValue.sqlValue,
                side.outcome.rawValue.sqlValue, game.endTime.sqlValue, game.timeClass.rawValue.sqlValue,
                game.rated.sqlValue, side.rating.sqlValue, game.openingLabel.sqlValue
            ])
    }

    /// Publishes free-window membership atomically after a successful bounded refresh (§4).
    /// The window is the newest 1,000 eligible games across all four classes combined.
    func publishFreeWindow(playerID: UUID, limit: Int) throws -> Int {
        try database.transaction {
            let version = (try database.queryUnsafe(
                "SELECT COALESCE(MAX(window_version), 0) AS value FROM player_games WHERE player_id = ?;",
                [playerID.sqlValue]).first?.int("value") ?? 0) + 1

            try database.runUnsafe("""
                UPDATE player_games SET in_window = 0, window_version = ? WHERE player_id = ?;
                """, [version.sqlValue, playerID.sqlValue])
            try database.runUnsafe("""
                UPDATE player_games SET in_window = 1
                WHERE player_id = ? AND game_key IN (
                    SELECT pg.game_key FROM player_games pg
                    JOIN games g ON g.game_key = pg.game_key
                    WHERE pg.player_id = ? AND g.rules = 'chess' AND g.parse_state != 'unsupported'
                    ORDER BY pg.end_time DESC, pg.game_key DESC
                    LIMIT ?
                );
                """, [playerID.sqlValue, playerID.sqlValue, limit.sqlValue])

            return try database.queryUnsafe(
                "SELECT COUNT(*) AS value FROM player_games WHERE player_id = ? AND in_window = 1;",
                [playerID.sqlValue]).first?.int("value") ?? 0
        }
    }

    // MARK: Reading

    func game(key: String) throws -> GameRecord? {
        try database.queryOne("SELECT * FROM games WHERE game_key = ?;", [key.sqlValue]).flatMap(Self.game)
    }

    func totalGameCount(playerID: UUID) throws -> Int {
        try database.queryOne("SELECT COUNT(*) AS value FROM player_games WHERE player_id = ?;",
                              [playerID.sqlValue])?.int("value") ?? 0
    }

    func windowCount(playerID: UUID) throws -> Int {
        try database.queryOne("SELECT COUNT(*) AS value FROM player_games WHERE player_id = ? AND in_window = 1;",
                              [playerID.sqlValue])?.int("value") ?? 0
    }

    /// Filter clause shared by the list, the counts and every aggregate, so the numbers on
    /// Analytics always describe the same sample as the list on Games.
    static func filterClause(filters: GameFilters, scope: PlanScope) -> (sql: String, parameters: [SQLValue]) {
        var sql = " AND pg.time_class = ?"
        var parameters: [SQLValue] = [filters.timeClass.rawValue.sqlValue]

        if scope == .freeWindow { sql += " AND pg.in_window = 1" }
        if let start = filters.dateRange.startDate() {
            sql += " AND pg.end_time >= ?"
            parameters.append(start.sqlValue)
        }
        if filters.colors.count == 1, let color = filters.colors.first {
            sql += " AND pg.color = ?"
            parameters.append(color.rawValue.sqlValue)
        }
        if filters.includeRated != filters.includeUnrated {
            sql += " AND pg.rated = ?"
            parameters.append((filters.includeRated ? 1 : 0).sqlValue)
        }
        return (sql, parameters)
    }

    func gameCount(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> Int {
        let clause = Self.filterClause(filters: filters, scope: scope)
        let sql = "SELECT COUNT(*) AS value FROM player_games pg WHERE pg.player_id = ?" + clause.sql + ";"
        return try database.queryOne(sql, [playerID.sqlValue] + clause.parameters)?.int("value") ?? 0
    }

    /// How many rows `page` would list in all, for the same filters.
    func pageCount(playerID: UUID,
                   filters: GameFilters,
                   scope: PlanScope,
                   status: ReviewStatusFilter = .all,
                   savedReviewsOnly: Bool = false) throws -> Int {
        if status == .all && !savedReviewsOnly {
            return try gameCount(playerID: playerID, filters: filters, scope: scope)
        }
        let clause = Self.filterClause(filters: filters, scope: savedReviewsOnly ? .allDownloaded : scope)
        var sql = """
            SELECT COUNT(*) AS value FROM player_games pg
            LEFT JOIN analyses a ON a.id = (\(Self.preferredAnalysis))
            WHERE pg.player_id = ?
            """ + clause.sql
        sql += Self.statusClause(status: status, savedReviewsOnly: savedReviewsOnly) + ";"
        let parameters = [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters
        return try database.queryOne(sql, parameters)?.int("value") ?? 0
    }

    private static func statusClause(status: ReviewStatusFilter, savedReviewsOnly: Bool) -> String {
        var sql = ""
        switch status {
        case .all: break
        case .reviewed: sql += " AND a.status = 'complete'"
        case .notReviewed: sql += " AND (a.status IS NULL OR a.status != 'complete')"
        case .failed: sql += " AND a.status = 'failed'"
        }
        if savedReviewsOnly { sql += " AND a.status = 'complete'" }
        return sql
    }

    /// The review that counts for the game in `pg`: complete first, then a deep review, then the
    /// current policy, then the newest. Takes the current policy identifier as its one parameter.
    static let preferredAnalysis = """
        SELECT a2.id FROM analyses a2 WHERE a2.game_key = pg.game_key
        ORDER BY (a2.status = 'complete') DESC, (a2.policy_id = '\(DeepReview.identifier)') DESC,
                 (a2.policy_id = ?) DESC, COALESCE(a2.completed_at, a2.created_at) DESC
        LIMIT 1
        """

    /// The columns of one Games list row: the game, the player's side of it, its preferred review,
    /// and for a complete deep review the rolling accuracies and the error backlog.
    private static let entryColumns = """
        SELECT g.*, pg.color AS pg_color, pg.outcome AS pg_outcome, pg.in_window AS pg_in_window,
               a.status AS a_status, a.policy_id AS a_policy,
               CASE pg.color WHEN 0 THEN a.white_accuracy ELSE a.black_accuracy END AS a_accuracy,
               \(rollingAccuracy(days: 30)) AS a_accuracy_30,
               \(rollingAccuracy(days: 365)) AS a_accuracy_365,
               CASE WHEN \(isCompleteDeep) THEN (
                   SELECT COUNT(*) FROM move_labels l
                   WHERE l.analysis_id = a.id AND l.mover = pg.color AND l.severity IS NOT NULL
               ) ELSE 0 END AS a_errors,
               CASE WHEN \(isCompleteDeep) THEN (
                   SELECT COUNT(*) FROM move_labels l
                   WHERE l.analysis_id = a.id AND l.mover = pg.color AND l.severity IS NOT NULL
                     AND (EXISTS (SELECT 1 FROM solved_mistakes s WHERE s.game_key = pg.game_key AND s.ply = l.ply)
                          OR EXISTS (SELECT 1 FROM mistake_reviews r
                                     WHERE r.game_key = pg.game_key AND r.ply = l.ply AND r.ignored = 1))
               ) ELSE 0 END AS a_solved,
               EXISTS (SELECT 1 FROM queue_items q
                       WHERE q.game_key = pg.game_key AND q.state IN ('pending', 'running')) AS q_active
        """

    private static let isCompleteDeep = "a.status = 'complete' AND a.policy_id = '\(DeepReview.identifier)'"

    /// The player's mean deep-review accuracy in `pg`'s time class over the `days` up to and
    /// including `pg`, or NULL when `pg` itself has no complete deep review.
    private static func rollingAccuracy(days: Int) -> String {
        """
        CASE WHEN \(isCompleteDeep) THEN (
            SELECT AVG(CASE pw.color WHEN 0 THEN aw.white_accuracy ELSE aw.black_accuracy END)
            FROM player_games pw
            JOIN analyses aw ON aw.game_key = pw.game_key AND aw.policy_id = '\(DeepReview.identifier)'
                            AND aw.status = 'complete'
            WHERE pw.player_id = pg.player_id AND pw.time_class = pg.time_class
              AND pw.end_time BETWEEN pg.end_time - \(days * 86_400) AND pg.end_time
        ) END
        """
    }

    private static func listEntry(_ row: SQLRow) -> GameListEntry? {
        guard let game = game(row), let colorValue = row.int("pg_color"),
              let color = PieceColor(rawValue: colorValue) else { return nil }
        return GameListEntry(game: game,
                             color: color,
                             outcome: GameOutcome(rawValue: row.string("pg_outcome") ?? "") ?? .unknown,
                             inFreeWindow: row.bool("pg_in_window"),
                             analysisStatus: row.string("a_status").flatMap(AnalysisStatus.init(rawValue:)),
                             analysisPolicyID: row.string("a_policy"),
                             accuracy: row.double("a_accuracy"),
                             accuracy30Days: row.double("a_accuracy_30"),
                             accuracy12Months: row.double("a_accuracy_365"),
                             errorCount: row.int("a_errors") ?? 0,
                             solvedCount: row.int("a_solved") ?? 0,
                             isQueued: row.bool("q_active"))
    }

    /// One page of the Games list. 50-row batches keep large histories off the main thread (§9).
    func page(playerID: UUID,
              filters: GameFilters,
              scope: PlanScope,
              status: ReviewStatusFilter = .all,
              savedReviewsOnly: Bool = false,
              limit: Int = 50,
              offset: Int = 0) throws -> [GameListEntry] {
        let clause = Self.filterClause(filters: filters, scope: savedReviewsOnly ? .allDownloaded : scope)
        var sql = Self.entryColumns + """

            FROM player_games pg
            JOIN games g ON g.game_key = pg.game_key
            LEFT JOIN analyses a ON a.id = (\(Self.preferredAnalysis))
            WHERE pg.player_id = ?
            """
        var parameters: [SQLValue] = [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue]
        parameters.append(contentsOf: clause.parameters)
        sql += clause.sql
        sql += Self.statusClause(status: status, savedReviewsOnly: savedReviewsOnly)

        sql += " ORDER BY pg.end_time DESC, pg.game_key DESC LIMIT ? OFFSET ?;"
        parameters.append(limit.sqlValue)
        parameters.append(offset.sqlValue)

        return try database.query(sql, parameters).compactMap(Self.listEntry)
    }

    func entry(playerID: UUID, gameKey: String) throws -> GameListEntry? {
        let sql = Self.entryColumns + """

            FROM player_games pg
            JOIN games g ON g.game_key = pg.game_key
            LEFT JOIN analyses a ON a.id = (\(Self.preferredAnalysis))
            WHERE pg.player_id = ? AND pg.game_key = ?;
            """
        return try database.queryOne(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue, gameKey.sqlValue])
            .flatMap(Self.listEntry)
    }

    /// Eligible game keys newest first, used to build a bulk batch.
    /// Games a bulk run may analyse, newest first, optionally limited to one time class.
    /// - Parameter since: only games that ended at or after this moment.
    func eligibleKeys(playerID: UUID, scope: PlanScope, timeClass: TimeClass? = nil,
                      since: Date? = nil) throws -> [String] {
        var sql = """
            SELECT pg.game_key AS value FROM player_games pg
            JOIN games g ON g.game_key = pg.game_key
            WHERE pg.player_id = ? AND g.rules = 'chess' AND g.parse_state = 'parsed' AND g.ply_count > 0
            """
        var arguments: [SQLValue] = [playerID.sqlValue]
        if scope == .freeWindow { sql += " AND pg.in_window = 1" }
        if let timeClass {
            sql += " AND pg.time_class = ?"
            arguments.append(timeClass.rawValue.sqlValue)
        }
        if let since {
            sql += " AND pg.end_time >= ?"
            arguments.append(since.sqlValue)
        }
        sql += " ORDER BY pg.end_time DESC, pg.game_key DESC;"
        return try database.query(sql, arguments).compactMap { $0.string("value") }
    }

    func newestEndTime(playerID: UUID) throws -> Date? {
        try database.queryOne("SELECT MAX(end_time) AS value FROM player_games WHERE player_id = ?;",
                              [playerID.sqlValue])?.date("value")
    }

    static func game(_ row: SQLRow) -> GameRecord? {
        guard let key = row.string("game_key"), let endTime = row.date("end_time") else { return nil }
        return GameRecord(gameKey: key,
                          url: row.string("url") ?? "",
                          uuid: row.string("uuid"),
                          pgn: row.string("pgn") ?? "",
                          startFEN: row.string("start_fen") ?? ChessBoard.startFEN,
                          moveHash: row.string("move_hash") ?? "",
                          endTime: endTime,
                          timeClass: TimeClass(rawValue: row.string("time_class") ?? "rapid") ?? .rapid,
                          timeControl: row.string("time_control") ?? "",
                          rules: row.string("rules") ?? "chess",
                          rated: row.bool("rated"),
                          white: GameSide(username: row.string("white_username") ?? "",
                                          rating: row.int("white_rating"),
                                          resultCode: row.string("white_result") ?? ""),
                          black: GameSide(username: row.string("black_username") ?? "",
                                          rating: row.int("black_rating"),
                                          resultCode: row.string("black_result") ?? ""),
                          eco: row.string("eco"),
                          ecoURL: row.string("eco_url"),
                          openingName: row.string("opening_name"),
                          parseState: GameParseState(rawValue: row.string("parse_state") ?? "parsed") ?? .parsed,
                          plyCount: row.int("ply_count") ?? 0)
    }
}

/// Which games a metric is allowed to cover, decided by the current entitlement (§3).
enum PlanScope: String {
    case freeWindow
    case allDownloaded
}
