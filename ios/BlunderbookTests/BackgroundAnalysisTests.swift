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

/// The progress reported to the system while analysis continues in the background (§7).
final class BackgroundAnalysisTests: XCTestCase {

    func testProgressMovesWithEachUnitAndCountsWholeGames() {
        var progress = SessionProgress(remaining: 3)
        XCTAssertEqual(progress.totalUnits, 300)
        XCTAssertEqual(progress.completedUnits, 0)

        progress.beginGame(gameKey: "a")
        progress.advance(gameKey: "a", completed: 80, total: 160)
        XCTAssertEqual(progress.completedUnits, 50)
        XCTAssertEqual(progress.totalUnits, 300)

        progress.finishGame(gameKey: "a")
        progress.remaining = 2
        XCTAssertEqual(progress.completedUnits, 100)
        XCTAssertEqual(progress.totalUnits, 300)
    }

    func testGamesOnSeveralEnginesAddUp() {
        var progress = SessionProgress(remaining: 4)
        progress.beginGame(gameKey: "a")
        progress.beginGame(gameKey: "b")
        progress.advance(gameKey: "a", completed: 1, total: 2)
        progress.advance(gameKey: "b", completed: 1, total: 4)
        XCTAssertEqual(progress.completedUnits, 75)
        XCTAssertEqual(progress.remaining, 2, "both running games left the waiting count")
        XCTAssertEqual(progress.totalUnits, 400)

        progress.finishGame(gameKey: "b")
        XCTAssertEqual(progress.completedUnits, 150)
    }

    func testProgressForAGameNotStartedIsIgnored() {
        var progress = SessionProgress(remaining: 1)
        progress.advance(gameKey: "late", completed: 5, total: 10)
        XCTAssertEqual(progress.completedUnits, 0)
    }

    func testTotalNeverShrinksSoTheBarNeverJumpsBack() {
        var progress = SessionProgress(remaining: 5)
        progress.beginGame(gameKey: "a")
        progress.finishGame(gameKey: "a")
        // Cancelled work drops out of the store; the bar keeps its scale and simply finishes.
        progress.remaining = 0
        XCTAssertEqual(progress.totalUnits, 500)
        XCTAssertLessThanOrEqual(progress.completedUnits, progress.totalUnits)
    }

    func testWorkAddedMidSessionGrowsTheTotal() {
        var progress = SessionProgress(remaining: 1)
        progress.beginGame(gameKey: "a")
        progress.remaining = 4
        progress.advance(gameKey: "a", completed: 5, total: 10)
        XCTAssertEqual(progress.totalUnits, 500)
    }

    func testAnInterruptedGameReturnsToTheWaitingCount() {
        var progress = SessionProgress(remaining: 2)
        progress.beginGame(gameKey: "a")
        progress.advance(gameKey: "a", completed: 5, total: 10)
        progress.interruptGame(gameKey: "a")
        XCTAssertEqual(progress.completedUnits, 0, "an interrupted game starts over")
        XCTAssertEqual(progress.remaining, 2)
        XCTAssertEqual(progress.totalUnits, 200)
    }

    func testSubtitleNamesTheGameOrCountsThemWhenSeveralRun() {
        var progress = SessionProgress(remaining: 3)
        XCTAssertEqual(progress.subtitle(label: nil), "0 of 3 games")
        progress.beginGame(gameKey: "a")
        XCTAssertEqual(progress.subtitle(label: "alice vs bob"), "Game 1 of 3 · alice vs bob")
        progress.beginGame(gameKey: "b")
        XCTAssertEqual(progress.subtitle(label: "alice vs bob"), "0 of 3 games · 2 at once")
    }

    func testPermittedIdentifiersMatchWhatTheControllerSubmits() throws {
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        let processing = BackgroundAnalysisController.processingIdentifier
        let continued = BackgroundAnalysisController.continuedPrefix + UUID().uuidString
        XCTAssertTrue(permitted.contains(processing))
        XCTAssertTrue(permitted.contains { $0.hasSuffix(".*") && continued.hasPrefix(String($0.dropLast())) })

        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(modes.contains("processing"))
    }
}
