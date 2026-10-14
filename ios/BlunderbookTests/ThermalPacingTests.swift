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

/// How many engines bulk analysis may use at each temperature.
final class ThermalPacingTests: XCTestCase {

    private func plan(_ thermal: ProcessInfo.ThermalState, engines: Int = 4) -> ThermalPacing.Plan {
        ThermalPacing.plan(thermal: thermal, efficiencyEngines: engines)
    }

    func testACoolPhoneUsesEveryEngine() {
        XCTAssertEqual(plan(.nominal), ThermalPacing.Plan(performanceBulk: true, efficiencyEngines: 4))
    }

    func testAWarmPhoneKeepsOnlyTheEfficiencyEngines() {
        XCTAssertEqual(plan(.fair), ThermalPacing.Plan(performanceBulk: false, efficiencyEngines: 4))
    }

    func testAHotPhoneRunsNothing() {
        // The thermal blocker stops everything; the plan agrees.
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            XCTAssertEqual(plan(state), ThermalPacing.Plan(performanceBulk: false, efficiencyEngines: 0))
        }
    }

    func testThePlanFollowsTheLearnedLimit() {
        XCTAssertEqual(plan(.nominal, engines: 2).efficiencyEngines, 2)
    }

    func testEnginesLeaveTheDeviceAFastCoreAndHalfItsEfficiencyCores() {
        func counts(_ p: Int, _ e: Int, _ gib: Int) -> [Int] {
            let result = ThermalPacing.engineCounts(performanceCores: p, efficiencyCores: e, memoryGiB: gib)
            return [result.performance, result.efficiency]
        }
        XCTAssertEqual(counts(2, 4, 8), [1, 2], "iPhone 16 Pro")
        XCTAssertEqual(counts(2, 4, 6), [1, 2])
        XCTAssertEqual(counts(4, 6, 16), [3, 3], "M5 MacBook")
        XCTAssertEqual(counts(10, 4, 24), [7, 1], "M4 Pro: eight at most, performance cores first")
        XCTAssertEqual(counts(24, 8, 96), [7, 1])
        XCTAssertEqual(counts(2, 4, 2), [1, 1], "one engine per GiB of memory")
        XCTAssertEqual(counts(1, 0, 2), [1, 1], "always at least one of each")

        XCTAssertLessThanOrEqual(ThermalPacing.performanceEngineCount + ThermalPacing.efficiencyEngineCount,
                                 ThermalPacing.maximumEngines)
    }

    func testBulkLeavesThePerformanceCoresAloneInTheBackground() {
        XCTAssertTrue(ThermalPacing.plan(thermal: .nominal, efficiencyEngines: 2).performanceBulk)
        XCTAssertFalse(ThermalPacing.plan(thermal: .nominal, efficiencyEngines: 2, inBackground: true).performanceBulk)
        XCTAssertEqual(ThermalPacing.plan(thermal: .nominal, efficiencyEngines: 2, inBackground: true).efficiencyEngines, 2)
    }

    // MARK: - Learned limit

    func testGettingHotWhileAnalysingDropsOneEngine() {
        var limit = EfficiencyEngineLimit(maximum: 4)
        limit.update(thermal: .nominal, isWorking: true)
        limit.update(thermal: .serious, isWorking: true)
        XCTAssertEqual(limit.value, 3)
        // Still hot: the same episode, not another one.
        limit.update(thermal: .serious, isWorking: false)
        limit.update(thermal: .critical, isWorking: false)
        XCTAssertEqual(limit.value, 3)
        limit.update(thermal: .fair, isWorking: false)
        limit.update(thermal: .serious, isWorking: true)
        XCTAssertEqual(limit.value, 2, "a second episode costs another engine")
    }

    func testHeatFromElsewhereCostsNothing() {
        var limit = EfficiencyEngineLimit(maximum: 4)
        limit.update(thermal: .serious, isWorking: false)
        XCTAssertEqual(limit.value, 4)
    }

    func testNeverBelowOneEngine() {
        var limit = EfficiencyEngineLimit(maximum: 2)
        for _ in 0..<5 {
            limit.update(thermal: .fair, isWorking: true)
            limit.update(thermal: .critical, isWorking: true)
        }
        XCTAssertEqual(limit.value, 1)
    }

    func testALongCalmStretchBringsOneEngineBack() {
        var limit = EfficiencyEngineLimit(maximum: 4)
        let start = Date()
        limit.update(thermal: .serious, isWorking: true, now: start)
        XCTAssertEqual(limit.value, 3)
        limit.update(thermal: .nominal, isWorking: true, now: start.addingTimeInterval(60))
        limit.update(thermal: .nominal, isWorking: true,
                     now: start.addingTimeInterval(60 + EfficiencyEngineLimit.recoverySeconds - 1))
        XCTAssertEqual(limit.value, 3)
        limit.update(thermal: .nominal, isWorking: true,
                     now: start.addingTimeInterval(60 + EfficiencyEngineLimit.recoverySeconds))
        XCTAssertEqual(limit.value, 4)
    }

    func testWarmthRestartsTheCalmClock() {
        var limit = EfficiencyEngineLimit(maximum: 4)
        let start = Date()
        limit.update(thermal: .serious, isWorking: true, now: start)
        limit.update(thermal: .nominal, isWorking: true, now: start)
        limit.update(thermal: .fair, isWorking: true, now: start.addingTimeInterval(EfficiencyEngineLimit.recoverySeconds / 2))
        limit.update(thermal: .nominal, isWorking: true, now: start.addingTimeInterval(EfficiencyEngineLimit.recoverySeconds + 1))
        XCTAssertEqual(limit.value, 3, "the calm stretch has to be unbroken")
    }
}
