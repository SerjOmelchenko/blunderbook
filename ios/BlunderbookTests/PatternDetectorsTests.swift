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

final class PatternDetectorsTests: XCTestCase {

    // MARK: Static exchange

    func testAnUndefendedPieceIsWonOutright() throws {
        let board = try XCTUnwrap(ChessBoard(fen: "4k3/8/3p4/4N3/8/8/8/4K3 b - - 0 1"))
        XCTAssertEqual(PatternDetectors.exchangeValue(of: try move("d6e5"), on: board), 3)
    }

    func testAPieceDefendedByAPawnStillLosesToAPawn() throws {
        let board = try XCTUnwrap(ChessBoard(fen: "4k3/8/3p4/4N3/3P4/8/8/4K3 b - - 0 1"))
        XCTAssertEqual(PatternDetectors.exchangeValue(of: try move("d6e5"), on: board), 2,
                       "knight for pawn: the defender does not save it")
    }

    func testTakingADefendedPieceWithSomethingDearerLoses() throws {
        let board = try XCTUnwrap(ChessBoard(fen: "4k3/8/8/4N3/3P4/8/7K/4r3 b - - 0 1"))
        XCTAssertEqual(PatternDetectors.exchangeValue(of: try move("e1e5"), on: board), -2)
    }

    // MARK: Hanging piece

    func testLeavingAPieceEnPriseIsAHangingPiece() throws {
        let result = try detect(fen: "4r1k1/8/8/4N3/8/8/8/4K3 w - - 0 1", played: "e1d2", reply: ["e8e5"])
        XCTAssertTrue(result.tags.contains(.undefendedPiece))
        XCTAssertEqual(result.consequence, .losesMaterial)
    }

    func testAPieceLostForAPawnIsHangingEvenWithADefender() throws {
        let result = try detect(fen: "6k1/8/3p4/4N3/3P4/8/8/4K3 w - - 0 1", played: "e1d2", reply: ["d6e5", "d4e5"])
        XCTAssertTrue(result.tags.contains(.undefendedPiece),
                      "detectors-1 missed this: the knight had a defender")
    }

    func testAnEvenTradeIsNotAHangingPiece() throws {
        let result = try detect(fen: "6k1/8/4b3/3N4/4P3/8/8/4K3 w - - 0 1", played: "e1d2", reply: ["e6d5", "e4d5"])
        XCTAssertFalse(result.tags.contains(.undefendedPiece))
    }

    // MARK: Missed capture

    func testNotTakingAFreePieceIsAMissedCapture() throws {
        let result = try detect(fen: "4k3/8/8/3n4/8/8/8/3QK3 w - - 0 1", played: "e1e2",
                                reply: [], best: ["d1d5"])
        XCTAssertEqual(result.tags, [.missedCapture])
        XCTAssertEqual(result.consequence, .missesMaterialGain)
    }

    func testPlayingTheCaptureIsNotAMiss() throws {
        let result = try detect(fen: "4k3/8/8/3n4/8/8/8/3QK3 w - - 0 1", played: "d1d5",
                                reply: [], best: ["d1d5"], isBest: true)
        XCTAssertFalse(result.tags.contains(.missedCapture))
    }

    // MARK: Helpers

    private func move(_ uci: String) throws -> Move { try XCTUnwrap(Move.fromUCI(uci)) }

    private func detect(fen: String, played: String, reply: [String], best: [String] = [],
                        isBest: Bool = false) throws -> DetectionResult {
        let before = try XCTUnwrap(ChessBoard(fen: fen))
        let playedMove = try move(played)
        XCTAssertTrue(before.isLegalMove(playedMove))
        let after = before.copy()
        after.makeMove(playedMove)
        let bestLine = try best.map(move)
        return PatternDetectors.detect(DetectionContext(boardBefore: before,
                                                        playedMove: playedMove,
                                                        boardAfter: after,
                                                        bestMove: isBest ? nil : bestLine.first,
                                                        bestLine: bestLine,
                                                        replyLine: try reply.map(move),
                                                        mover: before.sideToMove,
                                                        scoreBefore: .centipawns(0),
                                                        scoreAfter: .centipawns(-300),
                                                        loss: 25,
                                                        isBest: isBest))
    }
}
