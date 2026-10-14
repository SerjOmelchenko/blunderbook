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
final class MistakeDrillTests: XCTestCase {
    /// 1. Nh3 from the starting position, where the engine wanted 1. e4.
    private func makeDrill() -> MistakeDrillModel {
        MistakeDrillModel(occurrence: MistakeOccurrence(
            gameKey: "game", ply: 0, san: "Nh3", moveNumberLabel: "1.", severity: .inaccuracy,
            phase: .opening, explanation: "", opponent: "bob", endTime: Date(), color: .white,
            fenBefore: ChessBoard.startFEN, uci: "g1h3", scoreBefore: .centipawns(30),
            bestMoveUCI: "e2e4", bestMoveSAN: "e4"))
    }

    private func square(_ name: String) -> Int { Square.parse(name)! }

    func testTheBoardOpensBeforeTheMistakeWithItsArrow() {
        let drill = makeDrill()
        XCTAssertEqual(drill.presentation.pieces, ChessBoard(fen: ChessBoard.startFEN)!.snapshot)
        XCTAssertEqual(drill.presentation.mistakeMove, Move.fromUCI("g1h3"))
        XCTAssertEqual(drill.presentation.orientation, .white)
        XCTAssertEqual(drill.phase, .thinking)
    }

    func testPickingUpAPieceShowsWhereItCanGo() {
        let drill = makeDrill()
        drill.tap(square("e7")) {}
        XCTAssertNil(drill.presentation.selectedSquare, "the opponent's pieces stay put")
        drill.tap(square("e2")) {}
        XCTAssertEqual(drill.presentation.selectedSquare, square("e2"))
        XCTAssertEqual(Set(drill.presentation.targetSquares), [square("e3"), square("e4")])
        drill.tap(square("e2")) {}
        XCTAssertNil(drill.presentation.selectedSquare, "tapping it again puts it down")
    }

    func testTheEnginesMoveSolvesIt() {
        let drill = makeDrill()
        var solved = 0
        drill.tap(square("e2")) { solved += 1 }
        drill.tap(square("e4")) { solved += 1 }
        XCTAssertEqual(drill.phase, .solved(san: "e4", isEngineMove: true))
        XCTAssertEqual(solved, 1)
        XCTAssertNil(drill.presentation.mistakeMove, "the tried move replaces the mistake's arrow")
        drill.tap(square("d2")) { solved += 1 }
        XCTAssertNil(drill.presentation.selectedSquare, "a solved puzzle takes no more moves")
    }

    func testReplayingTheGameMoveIsWrong() {
        let drill = makeDrill()
        var solved = false
        drill.tap(square("g1")) { solved = true }
        drill.tap(square("h3")) { solved = true }
        XCTAssertEqual(drill.phase, .wrong(san: "Nh3", loss: nil, isGameMove: true))
        XCTAssertFalse(solved)
    }

    func testShowingTheAnswerDrawsTheEnginesMoveWithoutSolving() {
        let drill = makeDrill()
        drill.reveal()
        XCTAssertEqual(drill.phase, .revealed)
        XCTAssertEqual(drill.presentation.lineArrows, [Move.fromUCI("e2e4")!])
        drill.retry()
        XCTAssertEqual(drill.phase, .thinking)
        XCTAssertTrue(drill.presentation.lineArrows.isEmpty)
    }

    func testHintsRingThePieceThenNameThePatternThenShowTheAnswer() {
        let drill = makeDrill()
        var results: [DrillResult] = []
        drill.onResult = { results.append($0) }
        XCTAssertEqual(drill.hintTitle, "Hint")
        drill.hint()
        XCTAssertEqual(drill.presentation.targetRings, [square("e2")], "the piece to move is ringed")
        XCTAssertNil(drill.hintText)
        drill.hint()
        XCTAssertNotNil(drill.hintText)
        XCTAssertEqual(drill.hintTitle, "Show answer")
        drill.hint()
        XCTAssertEqual(drill.phase, .revealed)
        XCTAssertEqual(results, [.revealed])
        drill.retry()
        drill.tap(square("e2")) {}
        drill.tap(square("e4")) {}
        XCTAssertEqual(results, [.revealed], "only the first ending counts")
    }

    func testAFirstTrySolveIsCleanAndAHintedOneIsNot() {
        let clean = makeDrill()
        var cleanResult: DrillResult?
        clean.onResult = { cleanResult = $0 }
        clean.tap(square("e2")) {}
        clean.tap(square("e4")) {}
        XCTAssertEqual(cleanResult, .clean)

        let helped = makeDrill()
        var helpedResult: DrillResult?
        helped.onResult = { helpedResult = $0 }
        helped.hint()
        helped.tap(square("e2")) {}
        helped.tap(square("e4")) {}
        XCTAssertEqual(helpedResult, .helped)
    }

    func testAfterSolvingTheGameLineCanBePlayedOut() {
        let drill = makeDrill()
        drill.tap(square("e2")) {}
        drill.tap(square("e4")) {}
        drill.play(.game)
        XCTAssertEqual(drill.shownLine, .game)
        XCTAssertNil(drill.presentation.badge, "the tried move gives way to the line")
        XCTAssertEqual(drill.presentation.pieces, ChessBoard(fen: ChessBoard.startFEN)!.snapshot, "the line starts from the puzzle")
    }
}
