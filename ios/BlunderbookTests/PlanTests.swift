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

/// What the free plan holds back, and the sample games the locked Mistakes tab is previewed with.
@MainActor
final class PlanTests: XCTestCase {

    // MARK: - Free plan

    func testTheFreePlanTracksOnePlayer() {
        XCTAssertEqual(FreePlan.maxPlayers, 1)
        XCTAssertEqual(FreePlan.playersDescription, "one player")
    }

    func testOnlyTheTwoDeepestReviewDepthsArePremium() {
        XCTAssertEqual(ReviewDepth.allCases.filter(\.requiresPremium), [.deep, .deepest])
        XCTAssertEqual(ReviewDepth.allCases.filter { !$0.requiresPremium }.map(\.typicalDepth), [19, 23])
        XCTAssertFalse(ReviewDepth.default.requiresPremium)
        XCTAssertFalse(ReviewDepth.deepestFree.requiresPremium)
    }

    func testAPremiumDepthRunsAtTheDeepestFreeOneWithoutPremium() {
        XCTAssertEqual(ReviewDepth.deepest.available(isPremium: false), .balanced)
        XCTAssertEqual(ReviewDepth.deep.available(isPremium: false), .balanced)
        XCTAssertEqual(ReviewDepth.fast.available(isPremium: false), .fast)
        XCTAssertEqual(ReviewDepth.deepest.available(isPremium: true), .deepest)
    }

    // MARK: - Sample mistakes

    private func board(_ fen: String) throws -> ChessBoard {
        try XCTUnwrap(ChessBoard(fen: fen), "unreadable FEN \(fen)")
    }

    /// A bad sample would leave a puzzle in the preview that cannot be played.
    func testEverySampleIsALegalPositionWithTheMovesItNames() throws {
        for occurrence in SampleMistakes.occurrences(solved: []) {
            let start = try board(occurrence.fenBefore)
            XCTAssertEqual(start.sideToMove, occurrence.color, occurrence.id)
            let played = try XCTUnwrap(occurrence.move, occurrence.id)
            let best = try XCTUnwrap(occurrence.bestMove, occurrence.id)
            XCTAssertNotEqual(played, best, occurrence.id)
            XCTAssertTrue(start.isLegalMove(played), "\(occurrence.id): \(occurrence.uci) is not legal")
            XCTAssertTrue(start.isLegalMove(best), "\(occurrence.id): \(occurrence.bestMoveUCI ?? "") is not legal")
            XCTAssertEqual(start.san(for: played), occurrence.san, occurrence.id)
            XCTAssertEqual(start.san(for: best), occurrence.bestMoveSAN, occurrence.id)
        }
        XCTAssertEqual(Set(SampleMistakes.occurrences(solved: []).map(\.id)).count, SampleMistakes.samples.count,
                       "ids are unique")
    }

    /// Each sample's label is true of its position, not just asserted.
    func testEachSampleShowsWhatItsLabelSays() throws {
        let samples = Dictionary(uniqueKeysWithValues: SampleMistakes.occurrences(solved: []).map { ($0.gameKey, $0) })

        func after(_ key: String, _ moves: [String]) throws -> ChessBoard {
            let occurrence = try XCTUnwrap(samples[key])
            let position = try board(occurrence.fenBefore)
            for uci in moves {
                let move = try XCTUnwrap(Move.fromUCI(uci))
                XCTAssertTrue(position.isLegalMove(move), "\(key): \(uci)")
                position.makeMove(move)
            }
            return position
        }

        XCTAssertEqual(try after("sample-backrank", ["d1d8"]).terminalState(), .checkmate, "Rd8 is mate")
        XCTAssertEqual(try after("sample-scholar", ["g8f6", "h5f7"]).terminalState(), .checkmate, "Nf6 allows Qxf7#")
        // Ng5 leaves the knight to the queen; h6 lets the knight take on f7, hitting queen and rook.
        XCTAssertTrue(try after("sample-ng5", ["f3g5"]).isLegalMove(Move.fromUCI("d8g5")!))
        let forked = try after("sample-friedliver", ["h7h6", "g5f7"])
        let knight = Square.parse("f7")!
        XCTAssertTrue(forked.attackers(of: Square.parse("d8")!, by: .white).contains(knight), "Nxf7 hits the queen")
        XCTAssertTrue(forked.attackers(of: Square.parse("h8")!, by: .white).contains(knight), "and the rook")
        XCTAssertTrue(try after("sample-nxe5", []).san(for: Move.fromUCI("c6e5")!).contains("x"), "Nxe5 is a capture")
    }

    func testTheSampleBacklogCountsLikeTheRealOne() {
        let occurrences = SampleMistakes.occurrences(solved: SampleMistakes.initiallySolved)
        let backlog = SampleMistakes.backlog(of: occurrences)
        XCTAssertEqual(backlog.errors, SampleMistakes.samples.count)
        XCTAssertEqual(backlog.solved, 1)
        XCTAssertEqual(backlog.kinds.map(\.count).reduce(0, +), occurrences.map(\.kinds.count).reduce(0, +))
        // Patterns come before consequences.
        let firstOutcome = backlog.kinds.firstIndex { !$0.category.isPattern } ?? backlog.kinds.count
        XCTAssertTrue(backlog.kinds[firstOutcome...].allSatisfy { !$0.category.isPattern })
        XCTAssertEqual(SampleMistakes.breakdown.total, SampleMistakes.samples.count)
    }
}
