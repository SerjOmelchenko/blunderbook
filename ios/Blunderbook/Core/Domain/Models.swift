//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

// MARK: - Players

/// The site a tracked player's games come from. Each player belongs to exactly one site, and two
/// accounts with the same name on different sites are different players: nothing is ever merged
/// across sites, and every screen shows one player at a time.
enum Provider: String, Codable, CaseIterable, Hashable, Identifiable {
    case chessCom = "chesscom"
    case lichess

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chessCom: return "Chess.com"
        case .lichess: return "Lichess"
        }
    }

    /// The time classes the site files games under, in picker order. Lichess has Classical,
    /// which Chess.com folds into Rapid, so it only appears for Lichess players.
    var timeClasses: [TimeClass] {
        switch self {
        case .chessCom: return [.bullet, .blitz, .rapid, .daily]
        case .lichess: return [.bullet, .blitz, .rapid, .classical, .daily]
        }
    }

    /// Whether the site lets a player rename their account. Lichess only allows a change of case,
    /// so relinking a renamed profile is a Chess.com feature.
    var allowsRenames: Bool { self == .chessCom }

    /// Trim, reject control characters and path separators. Both sites use letters, digits,
    /// underscores and hyphens (§4).
    func normalize(username: String) -> String? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= (self == .lichess ? 30 : 60) else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("?"), !trimmed.contains("#") else { return nil }
        guard trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return trimmed
    }
}

enum PlayerSyncStatus: String, Codable, Hashable {
    case never
    case upToDate
    case downloading
    case offline
    case notFound
    case rateLimited
    case failed
    case usernameUnavailable

    var label: String {
        switch self {
        case .never: return "Not checked yet"
        case .upToDate: return "Up to date"
        case .downloading: return "Downloading"
        case .offline: return "Offline"
        case .notFound: return "Player not found"
        case .rateLimited: return "Rate limited"
        case .failed: return "Last refresh failed"
        case .usernameUnavailable: return "Username unavailable"
        }
    }

    var needsAttention: Bool {
        switch self {
        case .notFound, .usernameUnavailable, .failed, .rateLimited: return true
        default: return false
        }
    }
}

struct TrackedPlayer: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var provider: Provider = .chessCom
    /// Provider identity when the profile exposed one. Absent means a provisional local identity
    /// that must never be merged on username alone (§4). Lichess identities are stored as
    /// `lichess:<id>`, so they can never collide with a Chess.com player ID.
    var providerID: String?
    /// Case-folded username used for lookups.
    var username: String
    /// Casing as the provider displays it.
    var displayUsername: String
    var aliases: [String] = []
    var avatarURL: String?
    var country: String?
    var title: String?
    var lastChecked: Date?
    var lastSuccessfulRefresh: Date?
    var status: PlayerSyncStatus = .never
    var createdAt: Date = Date()
    /// Set once a bounded refresh has established free-window membership locally (§10).
    var hasVerifiedWindow: Bool = false

    var initials: String {
        String(displayUsername.prefix(2)).uppercased()
    }
}

// MARK: - Games

enum TimeClass: String, Codable, CaseIterable, Hashable, Identifiable {
    case bullet, blitz, rapid, classical, daily
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// For the time-class pickers, where five equal segments share one row: "Classical" does
    /// not fit beside the other four on a 6.1-inch phone.
    var pickerLabel: String { self == .classical ? "Classic" : label }
    /// Daily is always kept separate from live chess (§6).
    var isLive: Bool { self != .daily }
}

enum GameOutcome: String, Codable, Hashable, CaseIterable {
    case win, draw, loss, unknown

    var label: String {
        switch self {
        case .win: return "Win"
        case .draw: return "Draw"
        case .loss: return "Loss"
        case .unknown: return "Unknown"
        }
    }

    var shortLabel: String {
        switch self {
        case .win: return "W"
        case .draw: return "D"
        case .loss: return "L"
        case .unknown: return "?"
        }
    }
}

enum GameParseState: String, Codable, Hashable {
    case parsed
    case malformed
    case unsupported
}

struct GameSide: Hashable, Codable {
    var username: String
    var rating: Int?
    /// Raw provider result code, preserved verbatim (§4).
    var resultCode: String

    var outcome: GameOutcome { ResultCodes.outcome(for: resultCode) }
}

enum ResultCodes {
    /// Chess.com's codes. Lichess games are mapped onto the same vocabulary when they are
    /// downloaded; `draw` is its draw with no more specific reason.
    private static let drawCodes: Set<String> = [
        "agreed", "draw", "repetition", "stalemate", "insufficient", "50move", "timevsinsufficient"
    ]
    private static let lossCodes: Set<String> = [
        "checkmated", "timeout", "resigned", "lose", "abandoned", "threecheck", "kingofthehill", "bughousepartnerlose"
    ]

    static func outcome(for code: String) -> GameOutcome {
        let normalized = code.lowercased()
        if normalized == "win" { return .win }
        if drawCodes.contains(normalized) { return .draw }
        if lossCodes.contains(normalized) { return .loss }
        return .unknown
    }

    /// Human phrasing for the raw code, used next to the normalised outcome.
    static func description(for code: String) -> String {
        switch code.lowercased() {
        case "win": return "Won"
        case "checkmated": return "Checkmated"
        case "agreed": return "Draw agreed"
        case "draw": return "Draw"
        case "repetition": return "Repetition"
        case "timeout": return "Lost on time"
        case "resigned": return "Resigned"
        case "stalemate": return "Stalemate"
        case "lose": return "Lost"
        case "insufficient": return "Insufficient material"
        case "50move": return "Fifty-move rule"
        case "abandoned": return "Abandoned"
        case "timevsinsufficient": return "Time out vs insufficient material"
        default: return code.isEmpty ? "Unknown" : code
        }
    }
}

struct GameRecord: Identifiable, Hashable, Codable {
    /// Provider UUID when present, otherwise the canonical game URL (§4).
    var gameKey: String
    var url: String
    var uuid: String?
    var pgn: String
    var startFEN: String
    /// Hash of the starting position plus the move sequence; content changes invalidate analysis.
    var moveHash: String
    var endTime: Date
    var timeClass: TimeClass
    var timeControl: String
    var rules: String
    var rated: Bool
    var white: GameSide
    var black: GameSide
    var eco: String?
    var ecoURL: String?
    var openingName: String?
    var parseState: GameParseState
    var plyCount: Int

    var id: String { gameKey }

    func side(for color: PieceColor) -> GameSide { color == .white ? white : black }

    func opponent(of color: PieceColor) -> GameSide { color == .white ? black : white }

    var isSupported: Bool { rules == "chess" && parseState != .unsupported }

    /// Opening group label; missing metadata is "Unknown opening" and is never guessed from a slug.
    var openingLabel: String { openingName?.isEmpty == false ? openingName! : "Unknown opening" }

    var timeControlLabel: String {
        if timeClass == .daily {
            if let days = Int(timeControl.replacingOccurrences(of: "1/", with: "")) {
                let perMove = max(1, days / 86_400)
                return "\(perMove) day\(perMove == 1 ? "" : "s")/move"
            }
            return "Daily"
        }
        let parts = timeControl.split(separator: "+")
        guard let base = Int(parts.first ?? "") else { return timeControl }
        let minutes = base / 60
        let seconds = base % 60
        var text = minutes > 0 ? "\(minutes) min" : "\(seconds) sec"
        if minutes > 0, seconds > 0 { text = "\(minutes):\(String(format: "%02d", seconds))" }
        if parts.count > 1, let increment = Int(parts[1]), increment > 0 { text += " + \(increment)" }
        return text
    }
}

/// A tracked player's relationship to a game. Games shared by two tracked players are analysed
/// once but carry a separate membership row per player (§12).
struct PlayerGame: Hashable, Codable {
    var playerID: UUID
    var gameKey: String
    var color: PieceColor
    var outcome: GameOutcome
    /// Membership in the current free window, published atomically after a bounded refresh (§4).
    var inFreeWindow: Bool
    var windowVersion: Int
}

// MARK: - Analysis

enum AnalysisStatus: String, Codable, Hashable {
    case pending
    case running
    case complete
    case failed

    var label: String {
        switch self {
        case .pending: return "Not analysed"
        case .running: return "In progress"
        case .complete: return "Reviewed"
        case .failed: return "Analysis failed"
        }
    }
}

enum PatternTag: String, Codable, CaseIterable, Hashable, Identifiable {
    /// Stored as `undefendedPiece` since detectors-1; since detectors-2 it also covers a piece
    /// that is defended too few times, or only by something worth more than its attacker.
    case undefendedPiece
    case missedCapture
    case allowedFork
    case missedFork
    case allowedAbsolutePin
    case allowedMate
    case missedMate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .undefendedPiece: return "Hanging piece"
        case .missedCapture: return "Missed capture"
        case .allowedFork: return "Allowed fork"
        case .missedFork: return "Missed fork"
        case .allowedAbsolutePin: return "Allowed pin"
        case .allowedMate: return "Allowed mate"
        case .missedMate: return "Missed mate"
        }
    }

    var explanation: String {
        switch self {
        case .undefendedPiece: return "The reply wins a piece that was not defended enough."
        case .missedCapture: return "A capture that won material went unplayed."
        case .allowedFork: return "The reply attacks two pieces at once and wins material."
        case .missedFork: return "A fork was available and went unplayed."
        case .allowedAbsolutePin: return "A piece was pinned against the king and could not escape the cost."
        case .allowedMate: return "The move let a forced mate appear."
        case .missedMate: return "A forced mate was available and went unplayed."
        }
    }
}

/// Supported consequence of an error (§5). Generic evaluation loss is the fallback and never
/// claims a tactical cause.
enum Consequence: String, Codable, Hashable, CaseIterable {
    case losesMaterial
    case missesMaterialGain
    case allowsMate
    case missesForcedMate
    case lostWinningAdvantage
    case evaluationLoss

    var label: String {
        switch self {
        case .losesMaterial: return "Loses material"
        case .missesMaterialGain: return "Misses material"
        case .allowsMate: return "Allows mate"
        case .missesForcedMate: return "Misses forced mate"
        case .lostWinningAdvantage: return "Lost a winning position"
        case .evaluationLoss: return "Reduces the position evaluation"
        }
    }
}

/// What a deep review adds to a move (`DeepReview`). Standard analyses have none.
struct MoveLabels: Hashable, Codable {
    /// The engine's choice in the position before the move, in SAN; nil when the move was it.
    var bestMoveSAN: String?
    /// The engine's line from the position before the move.
    var bestLineSAN: [String]
    var bestLineUCI: [String]
    /// Whether both positions around the move were searched again at the confirmation budget.
    var confirmed: Bool
    var loss: Double
    var accuracy: Double
    var severity: Severity?
    var phase: GamePhase
    var tags: [PatternTag]
    var consequence: Consequence
    var explanation: String
    /// True when the played move was the engine's root choice: zero loss by construction (§5).
    var isBest: Bool
}

/// One move, with Stockfish's evaluation of the position before it and after it.
struct MoveAnalysis: Hashable, Codable, Identifiable {
    var ply: Int
    var mover: PieceColor
    var san: String
    var uci: String
    var fenBefore: String
    /// Evaluations of the positions before and after the move, in White's frame.
    var scoreBefore: EngineScore
    var scoreAfter: EngineScore
    /// Stockfish's line from the position after the move.
    var lineSAN: [String]
    var lineUCI: [String]
    /// Depth and nodes of the search of the position after the move.
    var depth: Int
    var nodes: Int
    /// Present only in a deep review.
    var labels: MoveLabels? = nil

    var id: Int { ply }

    var moveNumber: Int { ply / 2 + 1 }

    /// `12.` or `12…` prefix used by the move list.
    var moveNumberLabel: String { mover == .white ? "\(moveNumber)." : "\(moveNumber)\u{2026}" }

    /// How far the move moved the evaluation bar towards the side that played it, in bar points
    /// (the bar runs 0–100). Positive means the mover's share of the bar grew.
    var barChange: Double {
        let before = Scoring.winPercent(scoreBefore)
        let after = Scoring.winPercent(scoreAfter)
        return mover == .white ? after - before : before - after
    }

    var trend: EvalTrend { EvalTrend(barChange: barChange) }

    var severity: Severity? { labels?.severity }
    var isError: Bool { severity != nil }
}

/// Whether a move moved the evaluation bar towards its player or away.
enum EvalTrend: Hashable {
    case improved
    case declined
    case level

    /// Under a point either way is shown as level: smaller moves of the bar are search noise.
    static let threshold = 1.0

    init(barChange: Double) {
        if barChange >= Self.threshold { self = .improved }
        else if barChange <= -Self.threshold { self = .declined }
        else { self = .level }
    }

    var label: String {
        switch self {
        case .improved: return "Improved"
        case .declined: return "Declined"
        case .level: return "Level"
        }
    }

    var symbol: String {
        switch self {
        case .improved: return "arrow.up"
        case .declined: return "arrow.down"
        case .level: return "equal"
        }
    }
}

struct GameAnalysis: Hashable, Codable, Identifiable {
    var id: UUID = UUID()
    var gameKey: String
    var provenance: AnalysisProvenance
    var status: AnalysisStatus
    /// Plies analysed: the whole game once complete.
    var nextPly: Int
    /// Game accuracy per colour; deep reviews only.
    var whiteAccuracy: Double? = nil
    var blackAccuracy: Double? = nil
    var createdAt: Date = Date()
    var completedAt: Date?
    var errorMessage: String?
    var moves: [MoveAnalysis] = []

    func moves(by color: PieceColor) -> [MoveAnalysis] {
        moves.filter { $0.mover == color }
    }

    func accuracy(for color: PieceColor) -> Double? {
        color == .white ? whiteAccuracy : blackAccuracy
    }

    var isDeep: Bool { DeepReview.isDeep(policyID: provenance.policyID) }
}

// MARK: - Queue

enum QueueItemState: String, Codable, Hashable {
    case pending, running, completed, failed
}

enum QueueBlocker: String, Codable, CaseIterable, Hashable, Identifiable {
    case user
    case thermal
    case battery
    case lowPower
    case storage
    case system

    var id: String { rawValue }

    /// Highest priority first; the top reason is displayed and the rest stay discoverable (§7).
    var priority: Int {
        switch self {
        case .user: return 0
        case .storage: return 1
        case .thermal: return 2
        case .battery: return 3
        case .lowPower: return 4
        case .system: return 5
        }
    }

    var title: String {
        switch self {
        case .user: return "Paused"
        case .thermal: return "Device is too warm"
        case .battery: return "Battery is low"
        case .lowPower: return "Low Power Mode is on"
        case .storage: return "Storage is low"
        case .system: return "Waiting for the system"
        }
    }

    var detail: String {
        switch self {
        case .user: return "Only Resume starts this queue again."
        case .thermal: return "Analysis resumes once the device has been cool for a minute."
        case .battery: return "Bulk analysis resumes at 30% or while charging."
        case .lowPower: return "Turn off Low Power Mode to continue bulk analysis. Single reviews still run."
        case .storage: return "Free space below 500 MB. Work resumes above 750 MB. Nothing is deleted for you."
        case .system: return "The system has not granted background time yet."
        }
    }
}

struct QueueItem: Hashable, Codable, Identifiable {
    var id: UUID = UUID()
    var batchID: UUID
    /// Whose allowance paid for this job, so a refund goes back to the right player.
    var playerID: UUID?
    /// Which allowance pot was charged when the job was queued.
    var chargedBucket: AllowanceBucket = .none
    var gameKey: String
    var policyID: String
    /// Lower runs first. A manual review takes the performance-core engine, stopping any bulk game
    /// there; that game goes back to pending (§7).
    var priority: Int
    var state: QueueItemState
    var checkpointPly: Int
    var attempts: Int
    var errorMessage: String?
    var createdAt: Date
}

struct QueueBatch: Hashable, Codable, Identifiable {
    var id: UUID = UUID()
    var playerID: UUID
    var createdAt: Date
    var isCancelled: Bool
    var totalItems: Int
    var label: String
}

// MARK: - Filters

/// Preset date windows. Presets rather than a free-form range: every screen shares one filter,
/// and a named window is far easier to read back in a chart caption than two dates.
enum DateRange: String, Codable, CaseIterable, Identifiable, Hashable {
    case lastWeek
    case lastMonth
    case last90Days
    case lastYear
    case allTime

    var id: String { rawValue }

    /// Ordered for the chip row: narrowest first.
    static var displayOrder: [DateRange] { [.lastWeek, .lastMonth, .last90Days, .lastYear, .allTime] }

    var label: String {
        switch self {
        case .lastWeek: return "Week"
        case .lastMonth: return "Month"
        case .last90Days: return "90 days"
        case .lastYear: return "Year"
        case .allTime: return "All time"
        }
    }

    var longLabel: String {
        switch self {
        case .lastWeek: return "Last week"
        case .lastMonth: return "Last month"
        case .last90Days: return "Last 90 days"
        case .lastYear: return "Last year"
        case .allTime: return "All time"
        }
    }

    private var days: Int? {
        switch self {
        case .lastWeek: return 7
        case .lastMonth: return 30
        case .last90Days: return 90
        case .lastYear: return 365
        case .allTime: return nil
        }
    }

    /// Earliest completion time included, or nil for no lower bound.
    func startDate(now: Date = Date()) -> Date? {
        guard let days else { return nil }
        return Calendar.current.date(byAdding: .day, value: -days, to: now)
    }
}

/// Filters shared by Analytics, Games and Mistakes (§8). Review status stays local to a list.
struct GameFilters: Hashable, Codable {
    var timeClass: TimeClass = .rapid
    var dateRange: DateRange = .lastYear
    var colors: Set<PieceColor> = [.white, .black]
    var includeRated = true
    var includeUnrated = true

    static let `default` = GameFilters()

    var isDefault: Bool {
        dateRange == .lastYear && colors.count == 2 && includeRated && includeUnrated
    }

    /// The same filters across the whole history. The Games list always shows every game, so
    /// the date range chosen on Analytics never narrows it.
    var ignoringDates: GameFilters {
        var filters = self
        filters.dateRange = .allTime
        return filters
    }

    /// Active filters other than the date range, for screens that ignore it.
    var activeCountIgnoringDates: Int {
        activeCount - (dateRange != .lastYear ? 1 : 0)
    }

    var activeCount: Int {
        var count = 0
        if dateRange != .lastYear { count += 1 }
        if colors.count == 1 { count += 1 }
        if !(includeRated && includeUnrated) { count += 1 }
        return count
    }

    var summary: String {
        var parts: [String] = [timeClass.label, dateRange.longLabel]
        if colors.count == 1 { parts.append(colors.contains(.white) ? "White" : "Black") }
        if includeRated != includeUnrated { parts.append(includeRated ? "Rated" : "Unrated") }
        return parts.joined(separator: " · ")
    }
}

enum ReviewStatusFilter: String, CaseIterable, Identifiable, Codable {
    case all
    case reviewed
    case notReviewed
    case failed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .reviewed: return "Reviewed"
        case .notReviewed: return "Not reviewed"
        case .failed: return "Failed"
        }
    }
}

/// Raised when the free plan's tracked-player limit would be exceeded.
enum PlayerLimitError: LocalizedError {
    case freeLimitReached

    var errorDescription: String? {
        "The free plan tracks \(FreePlan.playersDescription)."
    }

    var recoverySuggestion: String? {
        "Remove a player, or subscribe to track as many as you like."
    }
}
