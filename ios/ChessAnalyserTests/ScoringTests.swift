//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import XCTest
@testable import ChessAnalyser

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

    func testSeverityThresholdBoundaries() {
        XCTAssertNil(Scoring.severity(forLoss: 4.999))
        XCTAssertEqual(Scoring.severity(forLoss: 5), .inaccuracy)
        XCTAssertEqual(Scoring.severity(forLoss: 9.999), .inaccuracy)
        XCTAssertEqual(Scoring.severity(forLoss: 10), .mistake)
        XCTAssertEqual(Scoring.severity(forLoss: 19.999), .mistake)
        XCTAssertEqual(Scoring.severity(forLoss: 20), .blunder)
    }

    func testLossIsNeverNegative() {
        let loss = Scoring.loss(before: .centipawns(-200), after: .centipawns(400))
        XCTAssertEqual(loss, 0, "a move that improves the evaluation loses nothing")
    }

    func testMoveAccuracy() {
        XCTAssertEqual(Scoring.moveAccuracy(loss: 0), 100)
        XCTAssertEqual(Scoring.moveAccuracy(loss: 5), 103.1668 * exp(-0.04354 * 5) - 3.1669, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(Scoring.moveAccuracy(loss: 100), 0)
        XCTAssertLessThanOrEqual(Scoring.moveAccuracy(loss: 0.0001), 100)
    }

    func testGameAccuracyIsArithmeticMean() {
        XCTAssertEqual(Scoring.gameAccuracy([100, 50]), 75)
        XCTAssertNil(Scoring.gameAccuracy([]), "zero moves means accuracy is unavailable, not zero")
    }

    func testScoreFrameConversionsAreReversible() {
        let mover = PieceColor.black
        let score = EngineScore.centipawns(137)
        let stored = score.normalizedToWhite(mover: mover)
        XCTAssertEqual(stored, .centipawns(-137))
        XCTAssertEqual(stored.fromWhite(to: mover), score)
    }

    func testPhaseClassification() {
        let opening = ChessBoard()
        XCTAssertEqual(Scoring.phase(beforePly: 0, board: opening), .opening)
        XCTAssertEqual(Scoring.phase(beforePly: 20, board: opening), .middlegame)

        // Two rooks and a bishop per side weigh 2+2+1 = 5 each, so 10 in total: still middlegame.
        let heavy = ChessBoard(fen: "r3kb1r/8/8/8/8/8/8/R3KB1R w KQkq - 0 1")!
        XCTAssertEqual(Scoring.phase(beforePly: 40, board: heavy), .middlegame)

        // A rook each is 4 in total, which is the endgame.
        let light = ChessBoard(fen: "r3k3/8/8/8/8/8/8/R3K3 w Qq - 0 1")!
        XCTAssertEqual(Scoring.phase(beforePly: 8, board: light), .endgame,
                       "endgame is decided by material, not by move number")
    }

    func testScoreStorageRoundTrip() {
        let scores: [EngineScore] = [.centipawns(0), .centipawns(-450), .mate(3), .mate(-2),
                                     .checkmate(perspectiveWon: true), .checkmate(perspectiveWon: false)]
        for score in scores {
            XCTAssertEqual(EngineScore.fromStorage(score.storageText), score)
        }
    }
}
