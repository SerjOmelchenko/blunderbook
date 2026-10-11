//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A way to pick out errors. Severity, phase and kind are independent views of the same error
/// moves, so their totals are not meant to add up to each other (§6).
///
/// The *kind* of an error is what its label on the Mistakes tab says: every pattern a line
/// demonstrates, or, when none does, what the move cost (`outcome`). Every error has a kind.
enum MistakeCategory: Hashable, Identifiable {
    case severity(Severity)
    case phase(GamePhase)
    case pattern(PatternTag)
    /// An error no pattern explains, by its consequence.
    case outcome(Consequence)

    /// An error's kinds: its patterns, or its consequence when it has none.
    static func kinds(tags: [PatternTag], consequence: Consequence) -> [MistakeCategory] {
        tags.isEmpty ? [.outcome(consequence)] : tags.map(MistakeCategory.pattern)
    }

    var id: String {
        switch self {
        case .severity(let value): return "severity:\(value.rawValue)"
        case .phase(let value): return "phase:\(value.rawValue)"
        case .pattern(let value): return "pattern:\(value.rawValue)"
        case .outcome(let value): return "outcome:\(value.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .severity(let value): return value.label
        case .phase(let value): return "\(value.label) errors"
        case .pattern(let value): return value.label
        case .outcome(let value):
            switch value {
            case .losesMaterial: return "Lost material"
            case .missesMaterialGain: return "Missed material"
            case .allowsMate: return "Allowed mate"
            case .missesForcedMate: return "Missed mate"
            case .lostWinningAdvantage: return "Let a win slip"
            case .evaluationLoss: return "No forcing line"
            }
        }
    }

    /// True for a kind that a line on the board demonstrates.
    var isPattern: Bool {
        if case .pattern = self { return true }
        return false
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
        case .outcome(let value):
            switch value {
            case .evaluationLoss:
                return "No forcing line wins or loses material here; the position simply got worse."
            default: return value.label + "."
            }
        }
    }
}

struct ErrorBreakdown: Hashable {
    var inaccuracies = 0
    var mistakes = 0
    var blunders = 0
    /// The player's moves in deep-reviewed games.
    var analysedMoves = 0
    /// Deep-reviewed games in the view.
    var games = 0

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
    /// The position the mistake was played in, and the move itself.
    var fenBefore: String = ""
    var uci: String = ""
    /// The review's evaluation of `fenBefore`, in White's frame: what a good move keeps.
    var scoreBefore: EngineScore = .centipawns(0)
    /// The engine's choice in that position, when the review kept one.
    var bestMoveUCI: String?
    var bestMoveSAN: String?
    /// Set once the person has found a better move on the Mistakes tab.
    var solvedAt: Date?
    /// What kind of mistake it was: its patterns, or its consequence when no pattern applies.
    var kinds: [MistakeCategory] = []
    var id: String { "\(gameKey)#\(ply)" }

    var isSolved: Bool { solvedAt != nil }
    var move: Move? { Move.fromUCI(uci) }
    var bestMove: Move? { bestMoveUCI.flatMap(Move.fromUCI) }
}

/// How many errors carry one kind, and how many of those are solved.
struct MistakeKindCount: Hashable, Identifiable {
    var category: MistakeCategory
    var count: Int
    var solved: Int
    var id: String { category.id }
}

/// The whole backlog: every error in the view, how many of them are solved, and how many of
/// each kind — patterns first, then the rest by consequence, each most frequent first.
struct MistakeBacklog: Hashable {
    var errors = 0
    var solved = 0
    var kinds: [MistakeKindCount] = []
}

struct AnalyticsCoverage: Hashable {
    var totalGames = 0
    var analysedGames = 0
    var failedGames = 0
    var incompleteGames = 0

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

/// Aggregates for Analytics and Mistakes, joined to the same filter clause the Games list uses, so
/// the numbers always describe one sample. Mistakes come from deep reviews only: a standard
/// analysis labels nothing.
final class StatisticsRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    private func base(playerID: UUID, filters: GameFilters, scope: PlanScope) -> (String, [SQLValue]) {
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        return (" FROM player_games pg WHERE pg.player_id = ?" + clause.sql, [playerID.sqlValue] + clause.parameters)
    }

    /// How many games in the view have a review. Any complete analysis counts, whatever its policy.
    func coverage(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> AnalyticsCoverage {
        let (from, parameters) = base(playerID: playerID, filters: filters, scope: scope)
        let policy = AnalysisPolicy.identifier.sqlValue

        var coverage = AnalyticsCoverage()
        coverage.totalGames = try database.queryOne("SELECT COUNT(*) AS value" + from + ";", parameters)?.int("value") ?? 0

        func countWithStatus(_ statuses: [String]) throws -> Int {
            let list = statuses.map { "'\($0)'" }.joined(separator: ",")
            let sql = """
                SELECT COUNT(*) AS value FROM player_games pg
                JOIN analyses a ON a.id = (\(GameRepository.preferredAnalysis))
                WHERE pg.player_id = ? AND a.status IN (\(list))
                """ + GameRepository.filterClause(filters: filters, scope: scope).sql + ";"
            return try database.queryOne(sql, [policy] + parameters)?.int("value") ?? 0
        }
        coverage.analysedGames = try countWithStatus(["complete"])
        coverage.failedGames = try countWithStatus(["failed"])
        coverage.incompleteGames = try countWithStatus(["running", "pending"])
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

    // MARK: - Mistakes (deep reviews)

    /// The player's labelled moves in the view: their side of every deep-reviewed game.
    /// - Parameter joins: further joins on `pg`, `a` and `l`, without parameters.
    /// - Parameter gameKey: only that game, whatever the filters, which might otherwise hide it.
    private func labelledMoves(playerID: UUID, filters: GameFilters, scope: PlanScope, gameKey: String? = nil,
                               joins: String = "") -> (String, [SQLValue]) {
        let clause = Self.viewClause(filters: filters, scope: scope, gameKey: gameKey)
        let sql = """
             FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            JOIN move_labels l ON l.analysis_id = a.id AND l.mover = pg.color
            \(joins)
            WHERE pg.player_id = ?
            """ + clause.sql
        return (sql, [DeepReview.identifier.sqlValue, playerID.sqlValue] + clause.parameters)
    }

    /// The filters' clause, or with `gameKey` that one game alone.
    private static func viewClause(filters: GameFilters, scope: PlanScope,
                                   gameKey: String?) -> (sql: String, parameters: [SQLValue]) {
        if let gameKey { return (" AND pg.game_key = ?", [gameKey.sqlValue]) }
        let clause = GameRepository.filterClause(filters: filters, scope: scope)
        return (clause.sql, clause.parameters)
    }

    func errorBreakdown(playerID: UUID, filters: GameFilters, scope: PlanScope,
                        gameKey: String? = nil) throws -> ErrorBreakdown {
        let (from, parameters) = labelledMoves(playerID: playerID, filters: filters, scope: scope, gameKey: gameKey)
        guard let row = try database.queryOne("""
            SELECT COALESCE(SUM(l.severity = 'inaccuracy'), 0) AS inaccuracies,
                   COALESCE(SUM(l.severity = 'mistake'), 0) AS mistakes,
                   COALESCE(SUM(l.severity = 'blunder'), 0) AS blunders,
                   COUNT(*) AS moves, COUNT(DISTINCT pg.game_key) AS games
            """ + from + ";", parameters) else { return ErrorBreakdown() }
        return ErrorBreakdown(inaccuracies: row.int("inaccuracies") ?? 0,
                              mistakes: row.int("mistakes") ?? 0,
                              blunders: row.int("blunders") ?? 0,
                              analysedMoves: row.int("moves") ?? 0,
                              games: row.int("games") ?? 0)
    }

    /// The player's mean game accuracy over deep-reviewed games in the view.
    func averageAccuracy(playerID: UUID, filters: GameFilters, scope: PlanScope,
                         gameKey: String? = nil) throws -> Double? {
        let clause = Self.viewClause(filters: filters, scope: scope, gameKey: gameKey)
        let sql = """
            SELECT AVG(CASE pg.color WHEN 0 THEN a.white_accuracy ELSE a.black_accuracy END) AS value
            FROM player_games pg
            JOIN analyses a ON a.game_key = pg.game_key AND a.policy_id = ? AND a.status = 'complete'
            WHERE pg.player_id = ?
            """ + clause.sql + ";"
        return try database.queryOne(sql, [DeepReview.identifier.sqlValue, playerID.sqlValue] + clause.parameters)?
            .double("value")
    }

    func phaseBreakdown(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> [PhaseBreakdown] {
        let (from, parameters) = labelledMoves(playerID: playerID, filters: filters, scope: scope)
        var byPhase: [GamePhase: PhaseBreakdown] = [:]
        for row in try database.query("""
            SELECT l.phase AS phase, COUNT(*) AS moves, COALESCE(SUM(l.severity IS NOT NULL), 0) AS errors
            """ + from + " GROUP BY l.phase;", parameters) {
            guard let phase = row.string("phase").flatMap(GamePhase.init(rawValue:)) else { continue }
            byPhase[phase] = PhaseBreakdown(phase: phase, errors: row.int("errors") ?? 0, moves: row.int("moves") ?? 0)
        }
        return GamePhase.allCases.map { byPhase[$0] ?? PhaseBreakdown(phase: $0, errors: 0, moves: 0) }
    }

    /// Errors per kind: patterns first, then consequences, each most frequent first. A move can
    /// carry several patterns; one with none counts once, under its consequence (§6).
    func tagCounts(playerID: UUID, filters: GameFilters, scope: PlanScope) throws -> [(category: MistakeCategory, count: Int)] {
        try mistakeBacklog(playerID: playerID, filters: filters, scope: scope).kinds
            .map { (category: $0.category, count: $0.count) }
    }

    /// The Mistakes tab's backlog: how many errors there are, how many are solved, and how many
    /// of each kind. The errors themselves come from `occurrences`.
    func mistakeBacklog(playerID: UUID, filters: GameFilters, scope: PlanScope,
                        gameKey: String? = nil) throws -> MistakeBacklog {
        let (from, parameters) = labelledMoves(playerID: playerID, filters: filters, scope: scope, gameKey: gameKey,
                                               joins: Self.solvedJoin)
        var counts: [MistakeCategory: (count: Int, solved: Int)] = [:]
        var backlog = MistakeBacklog()
        for row in try database.query("""
            SELECT l.tags AS tags, l.consequence AS consequence, s.solved_at IS NOT NULL AS solved
            """ + from + " AND l.severity IS NOT NULL;", parameters) {
            let isSolved = row.bool("solved")
            backlog.errors += 1
            if isSolved { backlog.solved += 1 }
            for category in Self.kinds(row) {
                counts[category, default: (0, 0)].count += 1
                if isSolved { counts[category, default: (0, 0)].solved += 1 }
            }
        }
        backlog.kinds = counts.map { MistakeKindCount(category: $0.key, count: $0.value.count, solved: $0.value.solved) }
            .sorted { first, second in
                if first.category.isPattern != second.category.isPattern { return first.category.isPattern }
                return first.count != second.count ? first.count > second.count : first.id < second.id
            }
        return backlog
    }

    private static func kinds(_ row: SQLRow) -> [MistakeCategory] {
        let tags = Set((row.string("tags") ?? "").split(separator: " ").compactMap { PatternTag(rawValue: String($0)) })
        return MistakeCategory.kinds(tags: PatternTag.allCases.filter(tags.contains),
                                     consequence: Consequence(rawValue: row.string("consequence") ?? "") ?? .evaluationLoss)
    }

    private static let solvedJoin = "LEFT JOIN solved_mistakes s ON s.game_key = pg.game_key AND s.ply = l.ply"

    /// Records that the person found a better move for the mistake at `ply`. Solving it again
    /// keeps the first date.
    func markSolved(gameKey: String, ply: Int, at date: Date = Date()) throws {
        _ = try database.run("INSERT OR IGNORE INTO solved_mistakes (game_key, ply, solved_at) VALUES (?, ?, ?);",
                             [gameKey.sqlValue, ply.sqlValue, date.sqlValue])
    }

    /// Errors newest first: every one in the view, or only those in `category`; with `gameKey`,
    /// only that game's.
    func occurrences(playerID: UUID,
                     filters: GameFilters,
                     scope: PlanScope,
                     category: MistakeCategory? = nil,
                     gameKey: String? = nil,
                     limit: Int = 50,
                     offset: Int = 0) throws -> [MistakeOccurrence] {
        let (from, parameters) = labelledMoves(playerID: playerID, filters: filters, scope: scope, gameKey: gameKey,
                                               joins: """
            JOIN move_evaluations e ON e.analysis_id = l.analysis_id AND e.ply = l.ply
            JOIN games g ON g.game_key = pg.game_key
            \(Self.solvedJoin)
            """)
        var condition = " AND l.severity IS NOT NULL"
        var extra: [SQLValue] = []
        switch category {
        case .severity(let severity)?:
            condition = " AND l.severity = ?"
            extra = [severity.rawValue.sqlValue]
        case .phase(let phase)?:
            condition += " AND l.phase = ?"
            extra = [phase.rawValue.sqlValue]
        case .pattern(let tag)?:
            condition += " AND (' ' || l.tags || ' ') LIKE ?"
            extra = ["% \(tag.rawValue) %".sqlValue]
        case .outcome(let consequence)?:
            condition += " AND l.tags = '' AND l.consequence = ?"
            extra = [consequence.rawValue.sqlValue]
        case nil:
            break
        }

        let sql = """
            SELECT l.ply AS ply, e.san AS san, l.severity AS severity, l.phase AS phase,
                   l.explanation AS explanation, pg.game_key AS game_key, pg.end_time AS end_time,
                   pg.color AS color, e.fen_before AS fen_before, e.uci AS uci,
                   e.score_before AS score_before, l.best_line_uci AS best_line_uci,
                   l.best_move_san AS best_move_san, s.solved_at AS solved_at,
                   l.tags AS tags, l.consequence AS consequence,
                   CASE pg.color WHEN 0 THEN g.black_username ELSE g.white_username END AS opponent
            """ + from + condition + " ORDER BY pg.end_time DESC, l.ply ASC LIMIT ? OFFSET ?;"

        return try database.query(sql, parameters + extra + [limit.sqlValue, offset.sqlValue]).compactMap { row in
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
                                     color: color,
                                     fenBefore: row.string("fen_before") ?? "",
                                     uci: row.string("uci") ?? "",
                                     scoreBefore: EngineScore.fromStorage(row.string("score_before") ?? ""),
                                     bestMoveUCI: (row.string("best_line_uci") ?? "").split(separator: " ").first.map(String.init),
                                     bestMoveSAN: row.string("best_move_san"),
                                     solvedAt: row.date("solved_at"),
                                     kinds: Self.kinds(row))
        }
    }
}
