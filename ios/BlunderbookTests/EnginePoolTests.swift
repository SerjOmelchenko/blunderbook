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

/// A review the person asks for borrows every engine that is free; an engine is never in two
/// places at once.
final class EnginePoolTests: XCTestCase {

    private final class FakeEngine: ChessEngine {
        var engineIdentifier: String { "fake" }
        var evaluationIdentifier: String { "fake" }
        var searchConfigurationIdentifier: String { "fake" }
        func newGame() {}
        func search(board: ChessBoard, nodeBudget: Int, cancellation: CancellationToken) -> SearchResult {
            .terminal(.centipawns(0))
        }
    }

    private func isBusy(_ taken: EnginePool.Taken) -> Bool {
        if case .busy = taken { return true }
        return false
    }

    func testAnEngineTakenByItsWorkerCannotBeBorrowed() {
        var loads = 0
        let pool = EnginePool(performance: FakeEngine()) { loads += 1; return FakeEngine() }
        guard case .engine = pool.take(.efficiency(1)) else { return XCTFail("the engine loads on first use") }

        XCTAssertTrue(pool.isAnyBusy([.efficiency(1)]))
        XCTAssertEqual(pool.borrow([.efficiency(1), .efficiency(2)]).map(\.role), [.efficiency(2)],
                       "only the free engine is lent, loaded on the way")
        XCTAssertEqual(loads, 2)

        pool.release([.efficiency(1)])
        XCTAssertTrue(isBusy(pool.take(.efficiency(2))), "a lent engine is busy for its own worker")
        pool.release([.efficiency(2)])
        guard case .engine = pool.take(.efficiency(2)) else { return XCTFail("and free again once returned") }
        XCTAssertEqual(loads, 2, "an engine loads once")
    }

    func testAnEngineThatCannotLoadIsNeverWaitedFor() {
        let pool = EnginePool(performance: FakeEngine()) { nil }
        guard case .unavailable = pool.take(.efficiency(1)) else { return XCTFail("it reports it cannot load") }
        XCTAssertFalse(pool.isAnyBusy([.efficiency(1)]))
        XCTAssertTrue(pool.borrow([.efficiency(1)]).isEmpty)
    }
}
