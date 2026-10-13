//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// How one drill of a mistake went.
enum DrillResult: String, Hashable {
    /// Found at the first try, with no hint and inside the speed drill's time.
    case clean
    /// Found after a wrong try, a hint or the timer running out.
    case helped
    /// The answer was shown.
    case revealed
}

/// How a mistake has gone in drills so far.
struct MistakeReview: Hashable {
    var drills = 0
    /// Clean solves in a row.
    var streak = 0
    /// The result of the first drill: `DrillResult`, or `solved` for one solved before results
    /// were kept.
    var firstResult: String?
    var lastResult: DrillResult?
    var lastAt: Date?
    /// When it comes back; nil once learned, or before its first drill.
    var dueAt: Date?
    var isIgnored = false
}

/// Spaced repetition for mistakes: a clean solve brings one back after 3, 10, then 30 days, and
/// a fourth clean solve in a row counts it learned. Any other result starts the streak again and
/// brings it back the next day.
enum MistakeSchedule {
    static let intervals: [Double] = [3, 10, 30]
    static var learnedStreak: Int { intervals.count + 1 }

    static func next(after result: DrillResult, streak: Int, at date: Date) -> (streak: Int, dueAt: Date?) {
        guard result == .clean else { return (0, date.addingTimeInterval(86_400)) }
        let streak = streak + 1
        guard streak < learnedStreak else { return (streak, nil) }
        return (streak, date.addingTimeInterval(intervals[streak - 1] * 86_400))
    }
}

/// Where a mistake stands in the repetition.
enum MistakeState: Hashable {
    /// Never drilled.
    case new
    /// Due today or overdue.
    case due
    /// Coming back on that date.
    case learning(Date)
    case learned

    var label: String {
        switch self {
        case .new: return "New"
        case .due: return "Due"
        case .learning(let date): return "In \(Self.days(until: date))"
        case .learned: return "Learned"
        }
    }

    static func days(until date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        return days <= 1 ? "1 day" : "\(days) days"
    }
}

extension MistakeOccurrence {
    func state(now: Date = Date(), calendar: Calendar = .current) -> MistakeState {
        guard let review, review.drills > 0 else { return isSolved ? .learned : .new }
        guard let dueAt = review.dueAt else { return review.streak >= MistakeSchedule.learnedStreak ? .learned : .new }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return dueAt < endOfToday ? .due : .learning(dueAt)
    }
}

/// The two or three moves that led to a mistake, so a drill can play them in before it asks.
struct DrillLeadIn: Equatable {
    var fen: String
    var moves: [Move]
}

/// Every error in the Mistakes tab's view with all it shows: clock, lines, opening and how it
/// has gone in drills. The tab works the rest out on screen (`MistakeBook`); deep reviews are
/// few enough to load whole.
final class MistakeBookRepository {
    private let database: SQLiteDatabase
    /// A game's clock never changes, and its PGN is the costly part to read.
    private var clocks: [String: GameClock?] = [:]

    init(database: SQLiteDatabase) { self.database = database }

    /// The player's errors in deep-reviewed games, newest first, leaving out the ignored ones.
    /// With `gameKey`, only that game's, whatever the filters.
    func occurrences(playerID: UUID, filters: GameFilters, scope: PlanScope,
                     gameKey: String? = nil) throws -> [MistakeOccurrence] {
        let clause: (sql: String, parameters: [SQLValue]) = gameKey.map { (" AND pg.game_key = ?", [$0.sqlValue]) }
            ?? GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT l.ply AS ply, e.san AS san, l.severity AS severity, l.phase AS phase,
                   l.explanation AS explanation, pg.game_key AS game_key, pg.end_time AS end_time,
                   pg.color AS color, pg.opening_name AS opening_name, e.fen_before AS fen_before, e.uci AS uci,
                   e.score_before AS score_before, e.score_after AS score_after, e.line_uci AS line_uci,
                   l.best_line_uci AS best_line_uci, l.best_move_san AS best_move_san, l.loss AS loss,
                   l.tags AS tags, l.consequence AS consequence, s.solved_at AS solved_at,
                   r.drills AS drills, r.streak AS streak, r.first_result AS first_result,
                   r.last_result AS last_result, r.last_at AS last_at, r.due_at AS due_at,
                   g.pgn AS pgn, g.time_control AS time_control,
                   CASE pg.color WHEN 0 THEN g.black_username ELSE g.white_username END AS opponent
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN move_labels l ON l.analysis_id = a.id AND l.mover = pg.color
            JOIN move_evaluations e ON e.analysis_id = l.analysis_id AND e.ply = l.ply
            JOIN games g ON g.game_key = pg.game_key
            LEFT JOIN solved_mistakes s ON s.game_key = pg.game_key AND s.ply = l.ply
            LEFT JOIN mistake_reviews r ON r.game_key = pg.game_key AND r.ply = l.ply
            WHERE pg.player_id = ? AND l.severity IS NOT NULL AND COALESCE(r.ignored, 0) = 0
            """ + clause.sql + " ORDER BY pg.end_time DESC, l.ply ASC;"
        let rows = try database.query(sql, [DeepReview.identifier.sqlValue, playerID.sqlValue] + clause.parameters)
        return rows.compactMap { row in
            guard let gameKey = row.string("game_key"), let ply = row.int("ply"),
                  let colorValue = row.int("color"), let color = PieceColor(rawValue: colorValue) else { return nil }
            let moveNumber = ply / 2 + 1
            let bestLine = (row.string("best_line_uci") ?? "").split(separator: " ").map(String.init)
            var occurrence = MistakeOccurrence(
                gameKey: gameKey,
                ply: ply,
                san: row.string("san") ?? "",
                moveNumberLabel: color == .white ? "\(moveNumber)." : "\(moveNumber)\u{2026}",
                severity: row.string("severity").flatMap(Severity.init(rawValue:)),
                phase: GamePhase(rawValue: row.string("phase") ?? "middlegame") ?? .middlegame,
                explanation: row.string("explanation") ?? "",
                opponent: row.string("opponent") ?? "",
                endTime: row.date("end_time") ?? Date(),
                color: color,
                fenBefore: row.string("fen_before") ?? "",
                uci: row.string("uci") ?? "",
                scoreBefore: EngineScore.fromStorage(row.string("score_before") ?? ""),
                bestMoveUCI: bestLine.first,
                bestMoveSAN: row.string("best_move_san"),
                solvedAt: row.date("solved_at"),
                kinds: StatisticsRepository.kinds(row))
            occurrence.loss = row.double("loss") ?? 0
            occurrence.scoreAfter = EngineScore.fromStorage(row.string("score_after") ?? "")
            occurrence.bestLineUCI = bestLine
            occurrence.replyLineUCI = (row.string("line_uci") ?? "").split(separator: " ").map(String.init)
            occurrence.openingName = row.string("opening_name")
            occurrence.clock = clock(gameKey: gameKey, ply: ply, pgn: row.string("pgn"),
                                     timeControl: row.string("time_control"))
            if let drills = row.int("drills") {
                occurrence.review = MistakeReview(drills: drills,
                                                  streak: row.int("streak") ?? 0,
                                                  firstResult: row.string("first_result"),
                                                  lastResult: row.string("last_result").flatMap(DrillResult.init(rawValue:)),
                                                  lastAt: row.date("last_at"),
                                                  dueAt: row.date("due_at"))
            }
            return occurrence
        }
    }

    private func clock(gameKey: String, ply: Int, pgn: String?, timeControl: String?) -> MistakeClock? {
        let gameClock: GameClock?
        if let cached = clocks[gameKey] {
            gameClock = cached
        } else {
            let parsed = pgn.flatMap { pgn in timeControl.flatMap { GameClock(clocks: PGNParser.parse(pgn).clocks, timeControl: $0) } }
            clocks[gameKey] = .some(parsed)
            gameClock = parsed
        }
        guard let gameClock, ply < gameClock.remaining.count else { return nil }
        return MistakeClock(spent: gameClock.spent[ply], remaining: gameClock.remaining[ply],
                            lowTime: gameClock.lowTime, base: gameClock.base)
    }

    // MARK: Drills

    /// Records one drill of each mistake. A solve also marks it solved, keeping the first date.
    func record(_ refs: [MistakeRef], result: DrillResult, at date: Date = Date()) throws {
        try database.transaction {
            for ref in refs {
                let current = try database.queryOne("SELECT streak FROM mistake_reviews WHERE game_key = ? AND ply = ?;",
                                                    [ref.gameKey.sqlValue, ref.ply.sqlValue])
                let next = MistakeSchedule.next(after: result, streak: current?.int("streak") ?? 0, at: date)
                _ = try database.run("""
                    INSERT INTO mistake_reviews (game_key, ply, drills, streak, first_result, last_result, last_at, due_at)
                    VALUES (?, ?, 1, ?, ?, ?, ?, ?)
                    ON CONFLICT (game_key, ply) DO UPDATE SET
                        drills = drills + 1, streak = excluded.streak, last_result = excluded.last_result,
                        last_at = excluded.last_at, due_at = excluded.due_at,
                        first_result = COALESCE(first_result, excluded.first_result);
                    """, [ref.gameKey.sqlValue, ref.ply.sqlValue, next.streak.sqlValue, result.rawValue.sqlValue,
                          result.rawValue.sqlValue, date.sqlValue, next.dueAt?.sqlValue ?? .null])
                if result != .revealed {
                    _ = try database.run("INSERT OR IGNORE INTO solved_mistakes (game_key, ply, solved_at) VALUES (?, ?, ?);",
                                         [ref.gameKey.sqlValue, ref.ply.sqlValue, date.sqlValue])
                }
            }
        }
    }

    /// Hides a mistake from the tab, or brings it back. An ignored mistake counts as dealt with
    /// for the game's check in Games.
    func setIgnored(_ refs: [MistakeRef], _ ignored: Bool) throws {
        try database.transaction {
            for ref in refs {
                _ = try database.run("""
                    INSERT INTO mistake_reviews (game_key, ply, ignored) VALUES (?, ?, ?)
                    ON CONFLICT (game_key, ply) DO UPDATE SET ignored = excluded.ignored;
                    """, [ref.gameKey.sqlValue, ref.ply.sqlValue, ignored.sqlValue])
            }
        }
    }

    /// The position `count` moves before the mistake and the moves from there to it, from the
    /// game's deep review; nil at the start of a game.
    func leadIn(gameKey: String, ply: Int, count: Int = 3) throws -> DrillLeadIn? {
        let first = max(0, ply - count)
        guard first < ply else { return nil }
        let rows = try database.query("""
            SELECT e.ply AS ply, e.fen_before AS fen_before, e.uci AS uci
            FROM analyses a JOIN move_evaluations e ON e.analysis_id = a.id
            WHERE a.game_key = ? AND a.policy_id = ? AND a.status = 'complete' AND e.ply >= ? AND e.ply < ?
            ORDER BY e.ply ASC;
            """, [gameKey.sqlValue, DeepReview.identifier.sqlValue, first.sqlValue, ply.sqlValue])
        guard rows.count == ply - first, let fen = rows.first?.string("fen_before") else { return nil }
        let moves = rows.compactMap { $0.string("uci").flatMap(Move.fromUCI) }
        guard moves.count == rows.count else { return nil }
        return DrillLeadIn(fen: fen, moves: moves)
    }
}
