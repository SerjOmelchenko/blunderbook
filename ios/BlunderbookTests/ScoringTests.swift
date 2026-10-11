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

final class ScoringTests: XCTestCase {

    func testWinPercentIsSymmetricAroundZero() {
        XCTAssertEqual(Scoring.winPercent(.centipawns(0)), 50, accuracy: 0.0001)
        for centipawns in [25, 100, 350, 1_200, 9_000] {
            let positive = Scoring.winPercent(.centipawns(centipawns))
            let negative = Scoring.winPercent(.centipawns(-centipawns))
            XCTAssertEqual(positive + negative, 100, accuracy: 0.0001,
                           "W(cp) + W(-cp) must equal 100 for cp = \(centipawns)")
        }
    }

    func testWinPercentBoundsExtremeEvaluations() {
        XCTAssertEqual(Scoring.winPercent(.centipawns(10_000)),
                       Scoring.winPercent(.centipawns(50_000)), accuracy: 0.0001)
        XCTAssertEqual(Scoring.winPercent(.mate(3)), 100)
        XCTAssertEqual(Scoring.winPercent(.mate(-1)), 0)
        XCTAssertEqual(Scoring.winPercent(.checkmate(perspectiveWon: true)), 100)
        XCTAssertEqual(Scoring.winPercent(.checkmate(perspectiveWon: false)), 0)
    }

    func testScoreFrameConversionsAreReversible() {
        let mover = PieceColor.black
        let score = EngineScore.centipawns(137)
        let stored = score.normalizedToWhite(mover: mover)
        XCTAssertEqual(stored, .centipawns(-137))
        XCTAssertEqual(stored.fromWhite(to: mover), score)
    }

    func testScoreStorageRoundTrip() {
        let scores: [EngineScore] = [.centipawns(0), .centipawns(-450), .mate(3), .mate(-2),
                                     .checkmate(perspectiveWon: true), .checkmate(perspectiveWon: false)]
        for score in scores {
            XCTAssertEqual(EngineScore.fromStorage(score.storageText), score)
        }
    }

    // MARK: - Evaluation bar

    private func move(_ mover: PieceColor, before: Int, after: Int) -> MoveAnalysis {
        MoveAnalysis(ply: mover == .white ? 0 : 1, mover: mover, san: "e4", uci: "e2e4",
                     fenBefore: ChessBoard.startFEN,
                     scoreBefore: .centipawns(before), scoreAfter: .centipawns(after),
                     lineSAN: [], lineUCI: [], depth: 1, nodes: 1)
    }

    func testABarMoveTowardsTheMoverIsAnImprovementForEitherColour() {
        // Scores are stored in White's frame: a rising score helps White, a falling one Black.
        XCTAssertEqual(move(.white, before: 0, after: 200).trend, .improved)
        XCTAssertEqual(move(.white, before: 0, after: -200).trend, .declined)
        XCTAssertEqual(move(.black, before: 0, after: -200).trend, .improved)
        XCTAssertEqual(move(.black, before: 0, after: 200).trend, .declined)
        XCTAssertEqual(move(.white, before: 0, after: 200).barChange,
                       -move(.black, before: 0, after: 200).barChange, accuracy: 1e-9)
    }

    func testSearchNoiseUnderAPointIsLevel() {
        XCTAssertEqual(move(.white, before: 30, after: 31).trend, .level)
        XCTAssertEqual(move(.black, before: -500, after: -490).trend, .level, "a decided position barely moves the bar")
    }

    func testMateFillsTheBar() {
        let mating = MoveAnalysis(ply: 0, mover: .white, san: "Qh5", uci: "d1h5", fenBefore: ChessBoard.startFEN,
                                  scoreBefore: .centipawns(0), scoreAfter: .mate(2),
                                  lineSAN: [], lineUCI: [], depth: 1, nodes: 1)
        XCTAssertEqual(mating.barChange, 50, accuracy: 1e-9)
    }
}
