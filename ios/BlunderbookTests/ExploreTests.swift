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

@MainActor
final class ExploreTests: XCTestCase {

    private func start(fen: String = ChessBoard.startFEN, history: [String] = [],
                       player: PieceColor = .white) -> ExploreStart {
        ExploreStart(startFEN: fen, history: history.compactMap(Move.fromUCI),
                     playerColor: player, orientation: player, origin: "Test")
    }

    /// Taps the from and to squares of a UCI move.
    private func play(_ uci: String, in explore: ExploreModel) {
        let move = Move.fromUCI(uci)!
        explore.tap(move.fromSquare)
        explore.tap(move.toSquare)
    }

    func testStartsFromTheGamesPositionWithItsHistory() {
        let explore = ExploreModel(start: start(history: ["e2e4", "e7e5"]))
        XCTAssertEqual(explore.board.sideToMove, .white)
        XCTAssertEqual(explore.board.playedMoves.map(\.uci), ["e2e4", "e7e5"])
        XCTAssertEqual(explore.presentation.lastMove, Move.fromUCI("e7e5"))
        XCTAssertFalse(explore.presentation.isHypothetical)
    }

    func testBothSidesTakesMovesForEitherColour() {
        let explore = ExploreModel(start: start())
        play("e2e4", in: explore)
        play("c7c5", in: explore)
        play("g1f3", in: explore)
        XCTAssertEqual(explore.sanLine, ["e4", "c5", "Nf3"])
        XCTAssertEqual(explore.cursor, 3)
        XCTAssertTrue(explore.presentation.isHypothetical)
        XCTAssertEqual(explore.chipLabel(0), "1.e4")
        XCTAssertEqual(explore.chipLabel(1), "c5")
        XCTAssertEqual(explore.chipLabel(2), "2.Nf3")
    }

    func testIllegalTapsMoveNothing() {
        let explore = ExploreModel(start: start())
        explore.tap(Move.fromUCI("e7e5")!.fromSquare)  // Black's piece, White to move.
        XCTAssertNil(explore.selected)
        explore.tap(Move.fromUCI("e2e5")!.fromSquare)
        explore.tap(Move.fromUCI("e2e5")!.toSquare)
        XCTAssertTrue(explore.line.isEmpty)
    }

    func testAMoveFromEarlierInTheLineStartsANewBranch() {
        let explore = ExploreModel(start: start())
        play("e2e4", in: explore)
        play("e7e5", in: explore)
        play("g1f3", in: explore)
        explore.go(to: 1)
        play("c7c5", in: explore)
        XCTAssertEqual(explore.sanLine, ["e4", "c5"])
        XCTAssertEqual(explore.cursor, 2)
    }

    func testReplayingTheLinesNextMoveKeepsTheRest() {
        let explore = ExploreModel(start: start())
        play("e2e4", in: explore)
        play("e7e5", in: explore)
        explore.go(to: 0)
        play("e2e4", in: explore)
        XCTAssertEqual(explore.sanLine, ["e4", "e5"])
        XCTAssertEqual(explore.cursor, 1)
    }

    func testAgainstTheEngineThePersonCannotMoveTheEnginesSide() {
        let explore = ExploreModel(start: start(history: ["e2e4"], player: .white), mode: .engine)
        XCTAssertTrue(explore.isEngineTurn)
        play("e7e5", in: explore)
        XCTAssertTrue(explore.line.isEmpty)
    }

    func testTakingBackAgainstTheEngineSkipsItsReplies() {
        let explore = ExploreModel(start: start())
        // Built in both-sides mode, then played on against the engine.
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6"] { play(uci, in: explore) }
        explore.mode = .engine
        explore.step(-1)
        XCTAssertEqual(explore.cursor, 2, "back to White's previous turn, past Black's reply")
        explore.step(-1)
        XCTAssertEqual(explore.cursor, 0)
        explore.step(1)
        XCTAssertEqual(explore.cursor, 2)
        explore.step(1)
        XCTAssertEqual(explore.cursor, 4)
    }

    func testPromotionWaitsForTheChoiceOfPiece() {
        let explore = ExploreModel(start: start(fen: "8/4P1k1/8/8/8/8/8/4K3 w - - 0 1"))
        play("e7e8", in: explore)
        XCTAssertEqual(explore.promotionChoices.count, 4)
        XCTAssertTrue(explore.line.isEmpty)
        explore.promote(to: .knight)
        XCTAssertEqual(explore.line.first?.promotion, .knight)
        XCTAssertEqual(explore.sanLine, ["e8=N+"])
    }

    func testCheckmateEndsTheLine() {
        let explore = ExploreModel(start: start())
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] { play(uci, in: explore) }
        XCTAssertEqual(explore.terminal, .checkmate)
        play("e1f2", in: explore)
        XCTAssertEqual(explore.line.count, 4)
        explore.reset()
        XCTAssertNil(explore.terminal)
        XCTAssertTrue(explore.line.isEmpty)
    }
}
