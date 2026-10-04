//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A facet of the Mistakes tab. Severity, phase and pattern are independent views of the same
/// error moves, so their totals are not meant to add up to each other (§6).
enum MistakeCategory: Hashable, Identifiable {
    case severity(Severity)
    case phase(GamePhase)
    case pattern(PatternTag)
    case unknownPattern

    static let unknownTagKey = "unknown"

    var id: String { storageKey }

    var storageKey: String {
        switch self {
        case .severity(let value): return "severity:\(value.rawValue)"
        case .phase(let value): return "phase:\(value.rawValue)"
        case .pattern(let value): return "pattern:\(value.rawValue)"
        case .unknownPattern: return "pattern:\(Self.unknownTagKey)"
        }
    }

    var title: String {
        switch self {
        case .severity(let value): return value.label
        case .phase(let value): return "\(value.label) errors"
        case .pattern(let value): return value.label
        case .unknownPattern: return "Unknown pattern"
        }
    }

    var detail: String {
        switch self {
        case .severity(let value):
            switch value {
            case .inaccuracy: return "Loss of 5 to 10 win-percentage points."
            case .mistake: return "Loss of 10 to 20 win-percentage points."
            case .blunder: return "Loss of 20 points or more."
            }
        case .phase(let value):
            switch value {
            case .opening: return "Player moves in the first 20 plies."
            case .middlegame: return "Player moves after the opening, before the endgame."
            case .endgame: return "Player moves once little material remains."
            }
        case .pattern(let value): return value.explanation
        case .unknownPattern: return "Errors with no supported pattern. The evaluation and line are still shown."
        }
    }
}

struct AnalyticsCoverage: Hashable {
    var totalGames = 0
    var analysedGames = 0
    var failedGames = 0
    var incompleteGames = 0
    var olderPolicyGames = 0
    var analysedMoves = 0

    var hasAnalysis: Bool { analysedGames > 0 }
    var fraction: Double { totalGames > 0 ? Double(analysedGames) / Double(totalGames) : 0 }
    /// "83 of 1,000 analysed" — always for the same player, filter and plan scope (§6).
    var summary: String { "\(analysedGames.formatted()) of \(totalGames.formatted()) games analysed" }
}

struct OutcomeCounts: Hashable {
    var win = 0, draw = 0, loss = 0, unknown = 0
    var total: Int { win + draw + loss + unknown }
    /// Unknown outcomes are excluded from percentages, with the denominator stated (§6).
    var decided: Int { win + draw + loss }
    func percentage(_ value: Int) -> Double { decided > 0 ? Double(value) * 100 / Double(decided) : 0 }
}

/// One point of the rating chart: a day (or, over long ranges, a week) of rated games.
struct RatingPoint: Hashable, Identifiable {
    /// When the period's last rated game finished.
    var date: Date
    /// Rating after that game: the period's closing rating.
    var rating: Int
    /// Rated games played in the period.
    var games: Int = 1
    var period: RatingPeriod = .game
    var id: Date { date }
}

enum RatingPeriod: Hashable {
    case game, day, week
}

enum RatingSeries {
    /// Above this many active days the chart switches to weekly points, so a long history stays
    /// light to draw without dropping any of it.
    static let maxDailyPoints = 730

    /// Reduces per-game ratings (oldest first) to one closing point per day, or per week for long
    /// ranges. Every game in the range counts; nothing is cut off by number.
    static func bucketed(_ games: [RatingPoint], calendar: Calendar = .current) -> [RatingPoint] {
        let daily = group(games, by: .day, calendar: calendar)
        return daily.count > maxDailyPoints ? group(games, by: .week, calendar: calendar) : daily
    }

    private static func group(_ games: [RatingPoint], by period: RatingPeriod, calendar: Calendar) -> [RatingPoint] {
        var result: [RatingPoint] = []
        var currentKey: Date?
        for game in games {
            let key = start(of: game.date, period: period, calendar: calendar)
            if key == currentKey, var last = result.popLast() {
                last.date = game.date
                last.rating = game.rating
                last.games += 1
                result.append(last)
            } else {
                result.append(RatingPoint(date: game.date, rating: game.rating, games: 1, period: period))
                currentKey = key
            }
        }
        return result
    }

    static func start(of date: Date, period: RatingPeriod, calendar: Calendar = .current) -> Date {
        switch period {
        case .game: return date
        case .day: return calendar.startOfDay(for: date)
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}

struct TrendPoint: Hashable, Identifiable {
    var date: Date
    var value: Double
    var sampleCount: Int
    var id: Date { date }
}

struct ErrorBreakdown: Hashable {
    var inaccuracies = 0
    var mistakes = 0
    var blunders = 0
    var analysedMoves = 0

    /// "Errors" is the union of all three severities; each move is counted once (§6).
    var total: Int { inaccuracies + mistakes + blunders }
    /// Errors per 100 analysed player moves, over the whole sample — never an average of
    /// per-game rates.
    var ratePer100: Double? {
        guard analysedMoves > 0 else { return nil }
        return Double(total) * 100 / Double(analysedMoves)
    }
    func count(for severity: Severity) -> Int {
        switch severity {
        case .inaccuracy: return inaccuracies
        case .mistake: return mistakes
        case .blunder: return blunders
        }
    }
}

struct PhaseBreakdown: Hashable, Identifiable {
    var phase: GamePhase
    var errors: Int
    var moves: Int
    var id: GamePhase { phase }
    var ratePer100: Double? { moves > 0 ? Double(errors) * 100 / Double(moves) : nil }
}

struct MistakeOccurrence: Hashable, Identifiable {
    var gameKey: String
    var ply: Int
    var san: String
    var moveNumberLabel: String
    var severity: Severity?
    var phase: GamePhase
    var explanation: String
    var opponent: String
    var endTime: Date
    var color: PieceColor
    var id: String { "\(gameKey)#\(ply)" }
}

/// Aggregates for Analytics and Mistakes. Everything reads the per-game summary tables, joined
/// to the same filter clause the Games list uses, so the numbers always describe one sample.
final class StatisticsRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    private func base(playerID: UUID, filters: GameFilters, scope: PlanScope) -> (String, [SQLValue]) {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        return (" FROM player_games pg WHERE pg.player_id = ?" + clause.sql, [playerID.sqlValue] + clause.parameters)
    }

    func coverage(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> AnalyticsCoverage {
        let (from, parameters) = base(playerID: playerID, filters: filters, scope: scope)
        let policy = AnalysisPolicy.identifier.sqlValue

        var coverage = AnalyticsCoverage()
        coverage.totalGames = try database.queryOne("SELECT COUNT(*) AS value" + from + ";", parameters)?.int("value") ?? 0

        let analysedSQL = """
            SELECT COUNT(*) AS value, COALESCE(SUM(s.moves), 0) AS moves
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_summaries s ON s.analysis_id = a.id AND s.color = pg.color
            WHERE pg.player_id = ?
            """ + GameRepository.filterClause(filters: filters, scope: scope).sql + ";"
        if let row = try database.queryOne(analysedSQL, [policy] + parameters) {
            coverage.analysedGames = row.int("value") ?? 0
            coverage.analysedMoves = row.int("moves") ?? 0
        }

        func countWithStatus(_ status: String) throws -> Int {
            let sql = """
                SELECT COUNT(*) AS value FROM player_games pg
                JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = ?
                WHERE pg.player_id = ?
                """ + GameRepository.filterClause(filters: filters, scope: scope).sql + ";"
            return try database.queryOne(sql, [policy, status.sqlValue] + parameters)?.int("value") ?? 0
        }
        coverage.failedGames = try countWithStatus("failed")
        coverage.incompleteGames = try countWithStatus("running") + (try countWithStatus("pending"))

        let olderSQL = """
            SELECT COUNT(DISTINCT pg.game_key) AS value FROM player_games pg
            JOIN analyses old ON old.game_key = pg.game_key AND old.policy_id != ? AND old.status = 'complete'
            LEFT JOIN analyses current ON current.game_key = pg.game_key AND current.policy_id = ? AND current.status = 'complete'
            WHERE pg.player_id = ? AND current.id IS NULL
            """ + GameRepository.filterClause(filters: filters, scope: scope).sql + ";"
        coverage.olderPolicyGames = try database.queryOne(olderSQL, [policy, policy] + parameters)?.int("value") ?? 0
        return coverage
    }

    func outcomes(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> OutcomeCounts {
        let (from, parameters) = base(playerID: playerID, filters: filters, scope: scope)
        var counts = OutcomeCounts()
        for row in try database.query("SELECT pg.outcome AS outcome, COUNT(*) AS value" + from + " GROUP BY pg.outcome;", parameters) {
            let value = row.int("value") ?? 0
            switch GameOutcome(rawValue: row.string("outcome") ?? "") ?? .unknown {
            case .win: counts.win = value
            case .draw: counts.draw = value
            case .loss: counts.loss = value
            case .unknown: counts.unknown = value
            }
        }
        return counts
    }

    /// Rated games only, ordered by completion time. A profile's current rating is never spliced
    /// into a filtered historical series (§6).
    /// Every rated game in the range, reduced to daily (or weekly) closing points. Never capped by
    /// count: a cap made "Last year" and "All time" draw the same recent games.
    func ratingSeries(playerID: UUID, filters: GameFilters, scope: PlanScope,
                      calendar: Calendar = .current) throws -> [RatingPoint] {
        var adjusted = filters
        adjusted.includeRated = true
        adjusted.includeUnrated = false
        let clause = GameRepository.filterClause(filters: adjusted, scope: scope)
        let sql = """
            SELECT pg.end_time AS end_time, pg.rating AS rating FROM player_games pg
            WHERE pg.player_id = ? AND pg.rating IS NOT NULL
            """ + clause.sql + " ORDER BY pg.end_time ASC;"
        let rows = try database.query(sql, [playerID.sqlValue] + clause.parameters)
        let games = rows.compactMap { row -> RatingPoint? in
            guard let date = row.date("end_time"), let rating = row.int("rating") else { return nil }
            return RatingPoint(date: date, rating: rating)
        }
        return RatingSeries.bucketed(games, calendar: calendar)
    }

    /// Highest rating reached in the current view, from rated games only.
    func bestRating(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> Int? {
        var adjusted = filters
        adjusted.includeRated = true
        adjusted.includeUnrated = false
        let clause = GameRepository.filterClause(filters: adjusted, scope: scope)
        let sql = """
            SELECT MAX(pg.rating) AS value FROM player_games pg
            WHERE pg.player_id = ? AND pg.rating IS NOT NULL
            """ + clause.sql + ";"
        return try database.queryOne(sql, [playerID.sqlValue] + clause.parameters)?.int("value")
    }

    func errorBreakdown(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> ErrorBreakdown {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT COALESCE(SUM(s.inaccuracies), 0) AS inaccuracies,
                   COALESCE(SUM(s.mistakes), 0) AS mistakes,
                   COALESCE(SUM(s.blunders), 0) AS blunders,
                   COALESCE(SUM(s.moves), 0) AS moves
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_summaries s ON s.analysis_id = a.id AND s.color = pg.color
            WHERE pg.player_id = ?
            """ + clause.sql + ";"
        guard let row = try database.queryOne(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters) else {
            return ErrorBreakdown()
        }
        return ErrorBreakdown(inaccuracies: row.int("inaccuracies") ?? 0,
                              mistakes: row.int("mistakes") ?? 0,
                              blunders: row.int("blunders") ?? 0,
                              analysedMoves: row.int("moves") ?? 0)
    }

    func averageAccuracy(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> Double? {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT AVG(s.accuracy) AS value FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_summaries s ON s.analysis_id = a.id AND s.color = pg.color
            WHERE pg.player_id = ? AND s.accuracy IS NOT NULL
            """ + clause.sql + ";"
        return try database.queryOne(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters)?.double("value")
    }

    func phaseBreakdown(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> [PhaseBreakdown] {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT COALESCE(SUM(s.opening_moves), 0) AS opening_moves,
                   COALESCE(SUM(s.middlegame_moves), 0) AS middlegame_moves,
                   COALESCE(SUM(s.endgame_moves), 0) AS endgame_moves,
                   COALESCE(SUM(s.opening_errors), 0) AS opening_errors,
                   COALESCE(SUM(s.middlegame_errors), 0) AS middlegame_errors,
                   COALESCE(SUM(s.endgame_errors), 0) AS endgame_errors
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_summaries s ON s.analysis_id = a.id AND s.color = pg.color
            WHERE pg.player_id = ?
            """ + clause.sql + ";"
        guard let row = try database.queryOne(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters) else { return [] }
        return [
            PhaseBreakdown(phase: .opening, errors: row.int("opening_errors") ?? 0, moves: row.int("opening_moves") ?? 0),
            PhaseBreakdown(phase: .middlegame, errors: row.int("middlegame_errors") ?? 0, moves: row.int("middlegame_moves") ?? 0),
            PhaseBreakdown(phase: .endgame, errors: row.int("endgame_errors") ?? 0, moves: row.int("endgame_moves") ?? 0)
        ]
    }

    func tagCounts(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> [(category: MistakeCategory, count: Int)] {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT t.tag AS tag, SUM(t.count) AS value FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_tag_summaries t ON t.analysis_id = a.id AND t.color = pg.color
            WHERE pg.player_id = ?
            """ + clause.sql + " GROUP BY t.tag ORDER BY value DESC;"
        return try database.query(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters)
            .compactMap { row in
                guard let key = row.string("tag"), let count = row.int("value") else { return nil }
                if key == MistakeCategory.unknownTagKey { return (.unknownPattern, count) }
                guard let tag = PatternTag(rawValue: key) else { return nil }
                return (.pattern(tag), count)
            }
    }

    /// Daily buckets of completed game accuracy, with the sample size behind each point (§5).
    func accuracyTrend(playerID: UUID, filters: GameFilters, scope: PlanScope, days: Int = 60) throws -> [TrendPoint] {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        let sql = """
            SELECT CAST(pg.end_time / 86400 AS INTEGER) AS bucket, AVG(s.accuracy) AS value, COUNT(*) AS samples
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN analysis_summaries s ON s.analysis_id = a.id AND s.color = pg.color
            WHERE pg.player_id = ? AND s.accuracy IS NOT NULL
            """ + clause.sql + " GROUP BY bucket ORDER BY bucket DESC LIMIT ?;"
        let rows = try database.query(sql, [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters + [days.sqlValue])
        return rows.compactMap { row -> TrendPoint? in
            guard let bucket = row.int("bucket"), let value = row.double("value") else { return nil }
            return TrendPoint(date: Date(timeIntervalSince1970: Double(bucket) * 86_400),
                              value: value,
                              sampleCount: row.int("samples") ?? 0)
        }.reversed()
    }

    func occurrences(playerID: UUID,
                     filters: GameFilters,
                     scope: PlanScope,
                     category: MistakeCategory,
                     limit: Int = 50,
                     offset: Int = 0) throws -> [MistakeOccurrence] {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        var conditions = ""
        var extra: [SQLValue] = []
        switch category {
        case .severity(let severity):
            conditions = " AND m.severity = ?"
            extra = [severity.rawValue.sqlValue]
        case .phase(let phase):
            conditions = " AND m.phase = ? AND m.severity IS NOT NULL"
            extra = [phase.rawValue.sqlValue]
        case .pattern(let tag):
            conditions = " AND m.severity IS NOT NULL AND EXISTS (SELECT 1 FROM move_tags mt WHERE mt.analysis_id = m.analysis_id AND mt.ply = m.ply AND mt.tag = ?)"
            extra = [tag.rawValue.sqlValue]
        case .unknownPattern:
            conditions = " AND m.severity IS NOT NULL AND NOT EXISTS (SELECT 1 FROM move_tags mt WHERE mt.analysis_id = m.analysis_id AND mt.ply = m.ply)"
        }

        let sql = """
            SELECT m.ply AS ply, m.san AS san, m.severity AS severity, m.phase AS phase,
                   m.explanation AS explanation, m.mover AS mover,
                   pg.game_key AS game_key, pg.end_time AS end_time, pg.color AS color,
                   CASE pg.color WHEN 0 THEN g.black_username ELSE g.white_username END AS opponent
            FROM player_games pg
            JOIN games g ON g.game_key = pg.game_key
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN move_analyses m ON m.analysis_id = a.id AND m.mover = pg.color
            WHERE pg.player_id = ?
            """ + clause.sql + conditions + " ORDER BY pg.end_time DESC, m.ply ASC LIMIT ? OFFSET ?;"

        let parameters = [AnalysisPolicy.identifier.sqlValue, playerID.sqlValue] + clause.parameters + extra + [limit.sqlValue, offset.sqlValue]
        return try database.query(sql, parameters).compactMap { row in
            guard let gameKey = row.string("game_key"), let ply = row.int("ply"),
                  let colorValue = row.int("color"), let color = PieceColor(rawValue: colorValue) else { return nil }
            let moveNumber = ply / 2 + 1
            return MistakeOccurrence(gameKey: gameKey,
                                     ply: ply,
                                     san: row.string("san") ?? "",
                                     moveNumberLabel: color == .white ? "\(moveNumber)." : "\(moveNumber)\u{2026}",
                                     severity: row.string("severity").flatMap(Severity.init(rawValue:)),
                                     phase: GamePhase(rawValue: row.string("phase") ?? "middlegame") ?? .middlegame,
                                     explanation: row.string("explanation") ?? "",
                                     opponent: row.string("opponent") ?? "",
                                     endTime: row.date("end_time") ?? Date(),
                                     color: color)
        }
    }
}
