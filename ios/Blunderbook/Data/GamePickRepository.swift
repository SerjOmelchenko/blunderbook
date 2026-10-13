//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Single games worth analysing next, for the quick rows on Analytics: the last loss, the
/// biggest upset, the latest game in the weakest opening, and one at random. Each looks at one
/// player's games of one time class, playable ones only, and returns one game.
final class GamePickRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    /// Games the engine can analyse: standard chess, readable, with at least one move.
    private static let playable = "g.rules = 'chess' AND g.parse_state != 'unsupported' AND g.ply_count > 0"

    /// The opponent's rating in the player's game.
    private static let opponentRating = "CASE pg.color WHEN 0 THEN g.black_rating ELSE g.white_rating END"

    /// The opening's family: "Sicilian Defense" for "Sicilian Defense: Najdorf Variation", so a
    /// score rests on enough games to mean something.
    private static let openingFamily = """
        CASE WHEN instr(pg.opening_name, ':') > 0 THEN substr(pg.opening_name, 1, instr(pg.opening_name, ':') - 1)
             ELSE pg.opening_name END
        """

    /// The most recent loss.
    func lastLoss(playerID: UUID, timeClass: TimeClass) throws -> String? {
        try database.queryOne("""
            SELECT pg.game_key AS value FROM player_games pg JOIN games g ON g.game_key = pg.game_key
            WHERE pg.player_id = ? AND pg.time_class = ? AND pg.outcome = 'loss' AND \(Self.playable)
            ORDER BY pg.end_time DESC LIMIT 1;
            """, [playerID.sqlValue, timeClass.rawValue.sqlValue])?.string("value")
    }

    struct Upset: Equatable {
        var gameKey: String
        /// How far the opponent was rated below the player, in points.
        var gap: Int
    }

    /// The loss to the opponent rated furthest below the player since `since`.
    func biggestUpset(playerID: UUID, timeClass: TimeClass, since: Date) throws -> Upset? {
        guard let row = try database.queryOne("""
            SELECT pg.game_key AS value, pg.rating - \(Self.opponentRating) AS gap
            FROM player_games pg JOIN games g ON g.game_key = pg.game_key
            WHERE pg.player_id = ? AND pg.time_class = ? AND pg.outcome = 'loss' AND pg.end_time >= ?
              AND pg.rating IS NOT NULL AND \(Self.opponentRating) IS NOT NULL
              AND pg.rating - \(Self.opponentRating) > 0 AND \(Self.playable)
            ORDER BY gap DESC, pg.end_time DESC LIMIT 1;
            """, [playerID.sqlValue, timeClass.rawValue.sqlValue, since.sqlValue]),
              let key = row.string("value"), let gap = row.int("gap") else { return nil }
        return Upset(gameKey: key, gap: gap)
    }

    struct WeakOpening: Equatable {
        /// The latest game in it.
        var gameKey: String
        var name: String
        /// Points per game, a draw counting a half: 0...1.
        var score: Double
        var games: Int
    }

    /// The opening family the player scores worst in, over at least `minimumGames` decided or
    /// drawn games, with its latest game. Ties go to the one played more.
    func weakestOpening(playerID: UUID, timeClass: TimeClass, minimumGames: Int = 5) throws -> WeakOpening? {
        guard let row = try database.queryOne("""
            SELECT \(Self.openingFamily) AS family, COUNT(*) AS n,
                   SUM(CASE pg.outcome WHEN 'win' THEN 1.0 WHEN 'draw' THEN 0.5 ELSE 0.0 END) AS points
            FROM player_games pg JOIN games g ON g.game_key = pg.game_key
            WHERE pg.player_id = ? AND pg.time_class = ? AND pg.outcome IN ('win', 'draw', 'loss')
              AND pg.opening_name IS NOT NULL AND pg.opening_name != '' AND pg.opening_name != 'Unknown opening'
              AND \(Self.playable)
            GROUP BY family HAVING n >= ?
            ORDER BY points * 1.0 / n ASC, n DESC LIMIT 1;
            """, [playerID.sqlValue, timeClass.rawValue.sqlValue, minimumGames.sqlValue]),
              let family = row.string("family"), let games = row.int("n"), let points = row.double("points"),
              let key = try database.queryOne("""
                  SELECT pg.game_key AS value FROM player_games pg JOIN games g ON g.game_key = pg.game_key
                  WHERE pg.player_id = ? AND pg.time_class = ? AND \(Self.openingFamily) = ? AND \(Self.playable)
                  ORDER BY pg.end_time DESC LIMIT 1;
                  """, [playerID.sqlValue, timeClass.rawValue.sqlValue, family.sqlValue])?.string("value")
        else { return nil }
        return WeakOpening(gameKey: key, name: family, score: points / Double(games), games: games)
    }

    /// A game picked at random, one without an in-depth review while there are any.
    func random(playerID: UUID, timeClass: TimeClass) throws -> String? {
        let base = """
            SELECT pg.game_key AS value FROM player_games pg JOIN games g ON g.game_key = pg.game_key
            WHERE pg.player_id = ? AND pg.time_class = ? AND \(Self.playable)
            """
        let unreviewed = try database.queryOne(base + """
             AND NOT EXISTS (SELECT 1 FROM analyses a WHERE a.game_key = pg.game_key
                             AND a.status = 'complete' AND a.policy_id = ?)
            ORDER BY RANDOM() LIMIT 1;
            """, [playerID.sqlValue, timeClass.rawValue.sqlValue, DeepReview.identifier.sqlValue])?.string("value")
        if let unreviewed { return unreviewed }
        return try database.queryOne(base + " ORDER BY RANDOM() LIMIT 1;",
                                     [playerID.sqlValue, timeClass.rawValue.sqlValue])?.string("value")
    }
}
