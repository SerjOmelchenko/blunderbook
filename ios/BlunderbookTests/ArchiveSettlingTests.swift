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

/// When a month's archive may stop being re-downloaded (§4).
final class ArchiveSettlingTests: XCTestCase {

    private func utc(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    func testAMonthFetchedWhileItWasRunningIsNeverSettled() {
        // The bug: fetched on the 29th, marked complete, and the last two days never arrived.
        XCTAssertFalse(ArchiveSyncService.isSettled(year: 2026, month: 9, fetchedAt: utc("2026-09-29T06:00:00Z")))
    }

    func testTheBoundaryIsUTCNotTheDeviceTimeZone() {
        // 01:40 on 1 October in Central Europe is still 30 September for the provider.
        XCTAssertFalse(ArchiveSyncService.isSettled(year: 2026, month: 9, fetchedAt: utc("2026-09-30T23:40:00Z")))
    }

    func testAMonthIsStillOpenJustAfterItEnds() {
        XCTAssertFalse(ArchiveSyncService.isSettled(year: 2026, month: 9, fetchedAt: utc("2026-10-01T12:00:00Z")))
    }

    func testAMonthSettlesADayAfterItEnds() {
        XCTAssertTrue(ArchiveSyncService.isSettled(year: 2026, month: 9, fetchedAt: utc("2026-10-02T00:00:00Z")))
        XCTAssertTrue(ArchiveSyncService.isSettled(year: 2026, month: 12, fetchedAt: utc("2027-01-02T00:00:01Z")))
    }

    func testAnUnfetchedMonthIsNotSettled() {
        XCTAssertFalse(ArchiveSyncService.isSettled(year: 2020, month: 1, fetchedAt: nil))
    }
}
