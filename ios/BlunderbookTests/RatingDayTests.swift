//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import Blunderbook

/// What the rating chart shows for the day under a finger.
final class RatingDayTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    /// Per-game ratings, oldest first, as the store returns them before bucketing.
    private var games: [RatingPoint] {
        [RatingPoint(date: at(20, 10), rating: 1400),
         RatingPoint(date: at(22, 9), rating: 1410),
         RatingPoint(date: at(22, 12), rating: 1402),
         RatingPoint(date: at(22, 18), rating: 1418),
         RatingPoint(date: at(25, 15), rating: 1425)]
    }

    private var points: [RatingPoint] { RatingSeries.bucketed(games, calendar: calendar) }

    func testGamesBecomeOneClosingPointPerDay() {
        XCTAssertEqual(points.map(\.games), [1, 3, 1])
        XCTAssertEqual(points.map(\.rating), [1400, 1418, 1425], "each day closes on its last game")
        XCTAssertEqual(points.map(\.period), [.day, .day, .day])
    }

    func testALongHistorySwitchesToWeeklyPoints() {
        let long = (0..<(RatingSeries.maxDailyPoints + 10)).map {
            RatingPoint(date: calendar.date(byAdding: .day, value: $0, to: at(1, 12))!, rating: 1400 + $0)
        }
        let points = RatingSeries.bucketed(long, calendar: calendar)
        XCTAssertTrue(points.allSatisfy { $0.period == .week })
        XCTAssertEqual(points.reduce(0) { $0 + $1.games }, long.count, "no game is dropped")
        XCTAssertEqual(points.last?.rating, long.last?.rating)
    }

    func testADaySummarisesAllItsGames() throws {
        let day = try XCTUnwrap(RatingDay.at(at(22, 13), in: points, calendar: calendar))
        XCTAssertEqual(day.games, 3)
        XCTAssertEqual(day.rating, 1418, "the rating after the day's last game")
        XCTAssertEqual(day.change, 18, "measured from the previous day's close")
        XCTAssertEqual(day.lastGame, at(22, 18))
    }

    func testTheNearestPointDecidesTheDay() throws {
        // The 24th has no games; the 25th's game is nearer than the 22nd's last.
        let day = try XCTUnwrap(RatingDay.at(at(24, 20), in: points, calendar: calendar))
        XCTAssertEqual(day.start, calendar.startOfDay(for: at(25, 0)))
        XCTAssertEqual(day.change, 7)
        XCTAssertEqual(day.games, 1)
    }

    func testTheFirstDayHasNothingToCompareWith() throws {
        let day = try XCTUnwrap(RatingDay.at(at(20, 10), in: points, calendar: calendar))
        XCTAssertNil(day.change)
    }

    func testNoGamesMeansNoDay() {
        XCTAssertNil(RatingDay.at(at(20, 10), in: [], calendar: calendar))
    }
}
