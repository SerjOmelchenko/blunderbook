//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

// MARK: - Time

/// How the clock stood when a mistake was played.
enum TimeTrait: String, CaseIterable, Hashable, Identifiable {
    /// Played in under five seconds.
    case rushed
    /// Played short of time (`GameClock.lowTime`).
    case timeTrouble
    /// After a long think: a twelfth of the starting time, at least 15 seconds.
    case longThink

    static let rushedSeconds: TimeInterval = 5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rushed: return "Rushed"
        case .timeTrouble: return "Time trouble"
        case .longThink: return "Long think"
        }
    }

    var caption: String {
        switch self {
        case .rushed: return "under 5 s"
        case .timeTrouble: return "short of time"
        case .longThink: return "thought long"
        }
    }

    var symbol: String {
        switch self {
        case .rushed: return "bolt.fill"
        case .timeTrouble: return "hourglass.bottomhalf.filled"
        case .longThink: return "clock"
        }
    }

    func matches(_ clock: MistakeClock) -> Bool {
        switch self {
        case .rushed:
            return (clock.spent ?? .infinity) < Self.rushedSeconds
        case .timeTrouble:
            return (clock.remaining ?? .infinity) < clock.lowTime
        case .longThink:
            return (clock.spent ?? 0) >= max(15, clock.base / 12)
        }
    }
}

extension MistakeOccurrence {
    func has(_ trait: TimeTrait) -> Bool { clock.map(trait.matches) ?? false }

    /// The speed drill is offered for mistakes made against the clock.
    var isAgainstTheClock: Bool { has(.rushed) || has(.timeTrouble) }

    /// The evaluation before and after, from the player's side: "+1.2 → −3.4".
    var swingText: String {
        "\(Self.short(scoreBefore.fromWhite(to: color))) \u{2192} \(Self.short(scoreAfter.fromWhite(to: color)))"
    }

    /// One decimal, or a mate count.
    static func short(_ score: EngineScore) -> String {
        switch score {
        case .centipawns(let value):
            return String(format: "%@%.1f", value >= 0 ? "+" : "\u{2212}", abs(Double(value) / 100))
        default:
            return score.displayText
        }
    }

    /// Same pieces, side to move, castling and en passant: the same position in another game.
    var positionKey: String { fenBefore.split(separator: " ").prefix(4).joined(separator: " ") }
}

// MARK: - Focus

/// A narrowing of the list beside its kind: one way of meeting the clock, one opening, or the
/// positions that keep going wrong.
enum MistakeFocus: Hashable {
    case time(TimeTrait)
    case opening(String)
    case repeated

    var title: String {
        switch self {
        case .time(let trait): return trait.title
        case .opening(let name): return name
        case .repeated: return "Repeated positions"
        }
    }

    var symbol: String {
        switch self {
        case .time(let trait): return trait.symbol
        case .opening: return "book.closed"
        case .repeated: return "square.on.square"
        }
    }
}

// MARK: - Openings

enum OpeningFamily {
    /// "French Defense Exchange Variation" → "French Defense", "Sicilian Defense: Najdorf
    /// Variation" → "Sicilian Defense": the name up to its first defence, game, opening, gambit,
    /// attack or system, so the variations of one opening count together.
    static func name(_ provider: String?) -> String? {
        guard let provider, !provider.isEmpty else { return nil }
        let head = provider.split(separator: ":").first.map(String.init) ?? provider
        var words: [Substring] = []
        for word in head.split(separator: " ") {
            words.append(word)
            if ["Defense", "Defence", "Game", "Opening", "Gambit", "Attack", "System"].contains(word) { break }
        }
        return words.joined(separator: " ")
    }

    /// Errors up to this move number count as the opening's.
    static let lastMove = 20
}

// MARK: - Book

/// The Mistakes tab worked out from its errors: what to drill, the biggest leak, how the clock
/// played in, where in the openings it goes wrong, and the list by week. Errors count one by
/// one; a position missed in several games is one puzzle, shown once.
struct MistakeBook {
    struct Leak: Equatable {
        var category: MistakeCategory
        var count: Int
        /// Of all errors.
        var share: Double
        /// In the last 30 days and the 30 before.
        var trend: Trend?
    }

    struct Trend: Equatable {
        var recent: Int
        var previous: Int
        var delta: Int { recent - previous }
    }

    struct TimeProfile: Equatable {
        /// Errors with a clock.
        var timed = 0
        var counts: [TimeTrait: Int] = [:]
        var timedBlunders = 0
        var rushedBlunders = 0

        func share(_ trait: TimeTrait) -> Double { timed > 0 ? Double(counts[trait] ?? 0) / Double(timed) : 0 }

        /// The one fact worth a line, when the clock shows a habit.
        var headline: String? {
            if timedBlunders >= 2, rushedBlunders > 0 {
                let percent = Int((Double(rushedBlunders) / Double(timedBlunders) * 100).rounded())
                return "\(percent)% of your blunders took under 5 seconds"
            }
            let trouble = counts[.timeTrouble] ?? 0
            if trouble > 0 { return "\(trouble) of \(timed) errors came short of time" }
            let rushed = counts[.rushed] ?? 0
            if rushed > 0 { return "\(rushed) of \(timed) errors took under 5 seconds" }
            return nil
        }
    }

    struct HotSpot: Equatable, Identifiable {
        var name: String
        var count: Int
        /// Where most of them fall, by move number.
        var moves: ClosedRange<Int>
        var id: String { name }

        var movesText: String {
            moves.lowerBound == moves.upperBound ? "move \(moves.lowerBound)" : "moves \(moves.lowerBound)\u{2013}\(moves.upperBound)"
        }
    }

    struct Section: Identifiable, Equatable {
        var start: Date
        var title: String
        var items: [MistakeOccurrence]
        var id: Date { start }

        var caption: String {
            let games = Set(items.map(\.gameKey)).count
            return "\(items.count) error\(items.count == 1 ? "" : "s") in \(games) game\(games == 1 ? "" : "s")"
        }
    }

    /// Every error, newest first.
    let all: [MistakeOccurrence]
    /// One per position: the newest, carrying the others as `repeats`.
    let puzzles: [MistakeOccurrence]
    let backlog: MistakeBacklog
    let trends: [MistakeCategory: Trend]
    let leak: Leak?
    let time: TimeProfile
    let hotSpots: [HotSpot]
    let repeatedCount: Int
    let dueToday: Int
    let reviewedToday: Int
    let firstTry: Double?
    let now: Date
    private let calendar: Calendar

    static let empty = MistakeBook(occurrences: [])

    init(occurrences: [MistakeOccurrence], now: Date = Date(), calendar: Calendar = .current) {
        self.all = occurrences
        self.now = now
        self.calendar = calendar

        // Repeats: the same position in more than one game.
        var byPosition: [String: [Int]] = [:]
        for (index, occurrence) in occurrences.enumerated() where !occurrence.fenBefore.isEmpty {
            byPosition[occurrence.positionKey, default: []].append(index)
        }
        var hidden = Set<Int>()
        var puzzles: [MistakeOccurrence] = []
        var repeated = 0
        for (index, occurrence) in occurrences.enumerated() where !hidden.contains(index) {
            var puzzle = occurrence
            let members = (byPosition[occurrence.positionKey] ?? []).filter { $0 != index }
            if !occurrence.fenBefore.isEmpty, Set(members.map { occurrences[$0].gameKey } + [occurrence.gameKey]).count > 1 {
                puzzle.repeats = members.map { occurrences[$0].ref }
                puzzle.repeatsSameMove = members.allSatisfy { occurrences[$0].uci == occurrence.uci }
                hidden.formUnion(members)
                repeated += 1
            }
            puzzles.append(puzzle)
        }
        self.puzzles = puzzles
        self.repeatedCount = repeated
        self.backlog = MistakeBacklog(counting: occurrences)

        // Trends: the last 30 days against the 30 before.
        let recentStart = now.addingTimeInterval(-30 * 86_400), previousStart = now.addingTimeInterval(-60 * 86_400)
        var trends: [MistakeCategory: Trend] = [:]
        for occurrence in occurrences {
            for kind in occurrence.kinds {
                if occurrence.endTime >= recentStart { trends[kind, default: Trend(recent: 0, previous: 0)].recent += 1 }
                else if occurrence.endTime >= previousStart { trends[kind, default: Trend(recent: 0, previous: 0)].previous += 1 }
            }
        }
        self.trends = trends

        // The biggest leak: the commonest pattern seen at least twice, otherwise the commonest
        // kind seen twice. With every kind seen once there is no leak to speak of.
        let kinds = backlog.kinds.filter { $0.count >= 2 }
        let pick = kinds.filter(\.category.isPattern).max { $0.count < $1.count } ?? kinds.max { $0.count < $1.count }
        self.leak = pick.map { kind in
            Leak(category: kind.category, count: kind.count,
                 share: occurrences.isEmpty ? 0 : Double(kind.count) / Double(occurrences.count),
                 trend: trends[kind.category])
        }

        // The clock.
        var time = TimeProfile()
        for occurrence in occurrences {
            guard let clock = occurrence.clock, clock.spent != nil || clock.remaining != nil else { continue }
            time.timed += 1
            for trait in TimeTrait.allCases where trait.matches(clock) { time.counts[trait, default: 0] += 1 }
            if occurrence.severity == .blunder {
                time.timedBlunders += 1
                if TimeTrait.rushed.matches(clock) { time.rushedBlunders += 1 }
            }
        }
        self.time = time

        // Openings: errors in the first 20 moves, by opening.
        var byOpening: [String: [Int]] = [:]
        for occurrence in occurrences {
            let moveNumber = occurrence.ply / 2 + 1
            guard moveNumber <= OpeningFamily.lastMove, let name = OpeningFamily.name(occurrence.openingName) else { continue }
            byOpening[name, default: []].append(moveNumber)
        }
        self.hotSpots = byOpening.compactMap { name, moves -> HotSpot? in
            guard moves.count >= 2 else { return nil }
            let sorted = moves.sorted()
            let low = sorted[sorted.count / 4], high = sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
            return HotSpot(name: name, count: moves.count, moves: low...high)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        .prefix(3).map { $0 }

        // Drills, by puzzle.
        let startOfToday = calendar.startOfDay(for: now)
        self.dueToday = puzzles.filter { $0.state(now: now, calendar: calendar) == .due }.count
        self.reviewedToday = puzzles.filter { ($0.review?.lastAt ?? .distantPast) >= startOfToday }.count
        let firsts = puzzles.compactMap { $0.review?.firstResult.flatMap(DrillResult.init(rawValue:)) }
        self.firstTry = firsts.isEmpty ? nil : Double(firsts.filter { $0 == .clean }.count) / Double(firsts.count)
    }

    // MARK: Figures

    var errors: Int { all.count }
    var solved: Int { all.filter(\.isSolved).count }
    var solvedShare: Double { errors > 0 ? Double(solved) / Double(errors) : 0 }
    /// Today's due puzzles done, of all that were due; with nothing due, all done.
    var dueCleared: Double {
        reviewedToday + dueToday > 0 ? Double(reviewedToday) / Double(reviewedToday + dueToday) : 1
    }
    var unsolvedPuzzles: Int { puzzles.filter { !$0.isSolved }.count }
    /// Every puzzle solved and none due.
    var isAllClear: Bool { errors > 0 && unsolvedPuzzles == 0 && dueToday == 0 }

    /// The next day a puzzle comes back, and how many come back that day.
    var nextReview: (date: Date, count: Int)? {
        let dates = puzzles.compactMap { puzzle -> Date? in
            if case .learning(let date) = puzzle.state(now: now, calendar: calendar) { return date }
            return nil
        }
        guard let first = dates.min() else { return nil }
        return (first, dates.filter { calendar.isDate($0, inSameDayAs: first) }.count)
    }

    func count(_ focus: MistakeFocus) -> Int {
        switch focus {
        case .time(let trait): return time.counts[trait] ?? 0
        case .opening(let name): return hotSpots.first { $0.name == name }?.count ?? 0
        case .repeated: return repeatedCount
        }
    }

    // MARK: List

    /// The puzzles to list, newest first.
    func shown(kind: MistakeCategory?, focus: MistakeFocus?) -> [MistakeOccurrence] {
        puzzles.filter { puzzle in
            if let kind, !puzzle.kinds.contains(kind) { return false }
            switch focus {
            case .time(let trait)?: return puzzle.has(trait)
            case .opening(let name)?:
                return puzzle.ply / 2 + 1 <= OpeningFamily.lastMove && OpeningFamily.name(puzzle.openingName) == name
            case .repeated?: return !puzzle.repeats.isEmpty
            case nil: return true
            }
        }
    }

    /// `items` by the week their game ended: "This week", "Last week", then the dates.
    func sections(_ items: [MistakeOccurrence]) -> [Section] {
        var sections: [Section] = []
        let thisWeek = RatingSeries.start(of: now, period: .week, calendar: calendar)
        for item in items {
            let start = RatingSeries.start(of: item.endTime, period: .week, calendar: calendar)
            if sections.last?.start == start {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(Section(start: start, title: title(week: start, thisWeek: thisWeek), items: [item]))
            }
        }
        return sections
    }

    private func title(week start: Date, thisWeek: Date) -> String {
        if start == thisWeek { return "This week" }
        if let last = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek), start == last { return "Last week" }
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let sameYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let first = start.formatted(style)
        let last = calendar.isDate(start, equalTo: end, toGranularity: .month) ? end.formatted(.dateTime.day()) : end.formatted(style)
        return "\(first) \u{2013} \(last)" + (sameYear ? "" : ", \(start.formatted(.dateTime.year()))")
    }

    // MARK: Training

    /// What a training session drills: puzzles due, oldest first, then new ones — up to two of the
    /// biggest leak first, then the newest.
    func trainingPick(count: Int = 5) -> [MistakeOccurrence] {
        let due = puzzles.filter { $0.state(now: now, calendar: calendar) == .due }
            .sorted { ($0.review?.dueAt ?? now) < ($1.review?.dueAt ?? now) }
        var pick = Array(due.prefix(count))
        let fresh = puzzles.filter { !$0.isSolved && $0.state(now: now, calendar: calendar) == .new }
        if let leak, pick.count < count {
            pick += fresh.filter { $0.kinds.contains(leak.category) }.prefix(min(2, count - pick.count))
        }
        for puzzle in fresh where pick.count < count && !pick.contains(where: { $0.id == puzzle.id }) {
            pick.append(puzzle)
        }
        return pick
    }

    /// The training button's line: "3 due · 2 new".
    var trainingCaption: String {
        let pick = trainingPick()
        let due = pick.filter { $0.state(now: now, calendar: calendar) == .due }.count
        let fresh = pick.count - due
        return [due > 0 ? "\(due) due" : nil, fresh > 0 ? "\(fresh) new" : nil].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}
