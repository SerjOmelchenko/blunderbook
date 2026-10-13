//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import Blunderbook

final class MistakeBookTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func mistake(_ game: String, ply: Int = 10, fen: String? = nil, uci: String = "e2e4",
                         daysAgo: Double = 1, kinds: [MistakeCategory] = [.pattern(.undefendedPiece)],
                         severity: Severity = .mistake, clock: MistakeClock? = nil, opening: String? = nil,
                         review: MistakeReview? = nil, solved: Bool = false) -> MistakeOccurrence {
        var occurrence = MistakeOccurrence(gameKey: game, ply: ply, san: "e4", moveNumberLabel: "6.",
                                           severity: severity, phase: .opening, explanation: "", opponent: "bob",
                                           endTime: now.addingTimeInterval(-daysAgo * 86_400), color: .white,
                                           fenBefore: fen ?? "8/8/8/8/8/8/8/\(game) w - - 0 1", uci: uci,
                                           solvedAt: solved ? now : nil, kinds: kinds)
        occurrence.clock = clock
        occurrence.openingName = opening
        occurrence.review = review
        return occurrence
    }

    private func book(_ occurrences: [MistakeOccurrence]) -> MistakeBook {
        MistakeBook(occurrences: occurrences, now: now, calendar: calendar)
    }

    // MARK: Schedule

    func testCleanSolvesSpaceOutAndTheFourthCountsLearned() {
        var streak = 0
        var gaps: [Double?] = []
        for _ in 0..<4 {
            let next = MistakeSchedule.next(after: .clean, streak: streak, at: now)
            streak = next.streak
            gaps.append(next.dueAt.map { $0.timeIntervalSince(now) / 86_400 })
        }
        XCTAssertEqual(gaps, [3, 10, 30, nil])
        XCTAssertEqual(MistakeSchedule.next(after: .helped, streak: 2, at: now).streak, 0)
        XCTAssertEqual(MistakeSchedule.next(after: .revealed, streak: 2, at: now).dueAt, now.addingTimeInterval(86_400))
    }

    func testStateFollowsTheReview() {
        XCTAssertEqual(mistake("a").state(now: now, calendar: calendar), .new)
        let due = MistakeReview(drills: 1, streak: 1, lastAt: now, dueAt: now.addingTimeInterval(-60))
        XCTAssertEqual(mistake("a", review: due).state(now: now, calendar: calendar), .due)
        let later = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(mistake("a", review: MistakeReview(drills: 1, streak: 1, dueAt: later)).state(now: now, calendar: calendar),
                       .learning(later))
        XCTAssertEqual(mistake("a", review: MistakeReview(drills: 4, streak: 4)).state(now: now, calendar: calendar), .learned)
    }

    // MARK: Book

    func testTheSamePositionInSeveralGamesIsOnePuzzle() {
        let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let book = book([mistake("a", fen: fen), mistake("b", fen: fen.replacingOccurrences(of: "0 1", with: "3 9")),
                         mistake("c")])
        XCTAssertEqual(book.errors, 3, "errors still count one by one")
        XCTAssertEqual(book.puzzles.count, 2)
        XCTAssertEqual(book.repeatedCount, 1)
        let repeated = book.puzzles[0]
        XCTAssertEqual(repeated.gameKey, "a", "the newest stands for the others")
        XCTAssertEqual(repeated.repeats, [MistakeRef(gameKey: "b", ply: 10)])
        XCTAssertTrue(repeated.repeatsSameMove)
        XCTAssertEqual(book.shown(kind: nil, focus: .repeated).map(\.gameKey), ["a"])
    }

    func testTheBiggestLeakPrefersAPatternAndKnowsItsTrend() {
        let book = book([
            mistake("a", daysAgo: 2, kinds: [.pattern(.allowedFork)]),
            mistake("b", daysAgo: 40, kinds: [.pattern(.allowedFork)]),
            mistake("c", daysAgo: 45, kinds: [.pattern(.allowedFork)]),
            mistake("d", kinds: [.outcome(.evaluationLoss)]),
            mistake("e", kinds: [.outcome(.evaluationLoss)]),
            mistake("f", kinds: [.outcome(.evaluationLoss)]),
            mistake("g", kinds: [.outcome(.evaluationLoss)]),
        ])
        let leak = try? XCTUnwrap(book.leak)
        XCTAssertEqual(leak?.category, .pattern(.allowedFork))
        XCTAssertEqual(leak?.count, 3)
        XCTAssertEqual(leak?.trend, MistakeBook.Trend(recent: 1, previous: 2))
    }

    func testTheClockSortsErrorsIntoTraits() {
        let base: TimeInterval = 300
        let rushed = MistakeClock(spent: 2, remaining: 200, lowTime: 30, base: base)
        let short = MistakeClock(spent: 8, remaining: 12, lowTime: 30, base: base)
        let long = MistakeClock(spent: 40, remaining: 150, lowTime: 30, base: base)
        let book = book([mistake("a", severity: .blunder, clock: rushed), mistake("b", severity: .blunder, clock: short),
                         mistake("c", clock: long), mistake("d")])
        XCTAssertEqual(book.time.timed, 3, "no clock, no trait")
        XCTAssertEqual(book.time.counts, [.rushed: 1, .timeTrouble: 1, .longThink: 1])
        XCTAssertEqual(book.time.headline, "50% of your blunders took under 5 seconds")
        XCTAssertEqual(book.shown(kind: nil, focus: .time(.longThink)).map(\.gameKey), ["c"])
    }

    func testOpeningHotSpotsGroupVariationsAndSayWhere() {
        XCTAssertEqual(OpeningFamily.name("French Defense Exchange Variation"), "French Defense")
        XCTAssertEqual(OpeningFamily.name("Sicilian Defense: Najdorf Variation"), "Sicilian Defense")
        XCTAssertEqual(OpeningFamily.name("Scotch Game"), "Scotch Game")
        let book = book([mistake("a", ply: 14, opening: "French Defense Exchange Variation"),
                         mistake("b", ply: 18, opening: "French Defense Advance Variation"),
                         mistake("c", ply: 60, opening: "French Defense"),
                         mistake("d", ply: 10, opening: "Scotch Game")])
        XCTAssertEqual(book.hotSpots, [MistakeBook.HotSpot(name: "French Defense", count: 2, moves: 8...10)],
                       "past move 20 does not count, nor an opening with one error")
        XCTAssertEqual(book.shown(kind: nil, focus: .opening("French Defense")).map(\.gameKey), ["a", "b"])
    }

    func testTheListIsByWeek() {
        let book = book([mistake("a", daysAgo: 0), mistake("b", daysAgo: 7), mistake("c", daysAgo: 30)])
        let sections = book.sections(book.puzzles)
        XCTAssertEqual(sections.map(\.title).prefix(2), ["This week", "Last week"])
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0].caption, "1 error in 1 game")
    }

    func testTrainingTakesDueFirstThenTheLeakThenTheNewest() {
        let due = MistakeReview(drills: 1, streak: 1, lastAt: now.addingTimeInterval(-3 * 86_400),
                                dueAt: now.addingTimeInterval(-60))
        let later = MistakeReview(drills: 1, streak: 1, dueAt: now.addingTimeInterval(5 * 86_400))
        let book = book([
            mistake("new1", daysAgo: 1, kinds: [.outcome(.evaluationLoss)]),
            mistake("new2", daysAgo: 2, kinds: [.outcome(.evaluationLoss)]),
            mistake("fork1", daysAgo: 3, kinds: [.pattern(.allowedFork)]),
            mistake("fork2", daysAgo: 4, kinds: [.pattern(.allowedFork)]),
            mistake("fork3", daysAgo: 5, kinds: [.pattern(.allowedFork)]),
            mistake("due", daysAgo: 6, review: due, solved: true),
            mistake("waiting", daysAgo: 7, review: later, solved: true),
        ])
        XCTAssertEqual(book.trainingPick().map(\.gameKey), ["due", "fork1", "fork2", "new1", "new2"])
        XCTAssertEqual(book.trainingCaption, "1 due \u{00B7} 4 new")
        XCTAssertEqual(book.dueToday, 1)
        XCTAssertFalse(book.isAllClear)
    }

    func testAllClearWhenEverythingIsSolvedAndNothingDue() {
        let later = now.addingTimeInterval(2 * 86_400)
        let book = book([mistake("a", review: MistakeReview(drills: 1, streak: 1, firstResult: "clean", dueAt: later), solved: true),
                         mistake("b", review: MistakeReview(drills: 1, streak: 0, firstResult: "helped", dueAt: later), solved: true)])
        XCTAssertTrue(book.isAllClear)
        XCTAssertEqual(book.firstTry, 0.5)
        XCTAssertEqual(book.dueCleared, 1, "nothing due counts as done")
        XCTAssertEqual(book.nextReview?.count, 2)
        XCTAssertTrue(book.trainingPick().isEmpty)
    }
}
