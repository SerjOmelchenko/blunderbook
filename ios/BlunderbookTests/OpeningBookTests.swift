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

final class OpeningBookTests: XCTestCase {
    private func moves(_ movetext: String) -> [Move] {
        let parsed = PGNParser.parse(movetext)
        XCTAssertNil(parsed.parseError)
        return parsed.moves
    }

    func testTheBundledBookLoads() {
        let start = Date()
        XCTAssertFalse(OpeningBook.shared.isEmpty)
        print("Opening book ready in \(Date().timeIntervalSince(start))s")
    }

    func testAGameIsNamedMoveByMoveAndLeavesTheBook() {
        let game = moves("1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. a4 a5 5. Qe2 Qe7")
        let trace = OpeningBook.shared.trace(startFEN: ChessBoard.startFEN, moves: game)
        XCTAssertEqual(trace.openings.count, game.count + 1)
        XCTAssertNil(trace.opening(afterPlies: 0), "nothing is named before the first move")
        XCTAssertEqual(trace.opening(afterPlies: 1)?.name, "King's Pawn Game")
        XCTAssertEqual(trace.opening(afterPlies: 5)?.name, "Italian Game")
        XCTAssertEqual(trace.opening(afterPlies: 6), Opening(eco: "C50", name: "Italian Game: Giuoco Piano"))
        XCTAssertTrue(trace.isBook(ply: 0))
        XCTAssertTrue(trace.isBook(ply: 5))
        XCTAssertLessThan(trace.bookMoves, game.count, "the queen moves at the end are not theory")
        XCTAssertFalse(trace.isBook(ply: game.count - 1))
        XCTAssertEqual(trace.opening(afterPlies: game.count), trace.opening(afterPlies: trace.bookMoves),
                       "the name stays once the game leaves the book")
    }

    func testTheBookEndsAtTheFirstMoveOffIt() {
        let trace = OpeningBook.shared.trace(startFEN: ChessBoard.startFEN, moves: moves("1. h4 h5 2. e4 e5"))
        XCTAssertEqual(trace.bookMoves, 1, "1. h4 is a named opening, 1... h5 is not theory")
        XCTAssertEqual(trace.opening?.name, "Kádas Opening")
        XCTAssertFalse(trace.isBook(ply: 3))
    }

    func testTranspositionsAreRecognised() {
        // The Queen's Gambit Declined reached with 1. c4 first.
        let direct = OpeningBook.shared.trace(startFEN: ChessBoard.startFEN, moves: moves("1. d4 d5 2. c4 e6"))
        let transposed = OpeningBook.shared.trace(startFEN: ChessBoard.startFEN, moves: moves("1. c4 e6 2. d4 d5"))
        XCTAssertEqual(direct.bookMoves, 4)
        XCTAssertEqual(transposed.bookMoves, 4)
        XCTAssertEqual(direct.opening, transposed.opening)
    }

    func testABookTrapIsStillABlunder() {
        let trace = OpeningBook.shared.trace(startFEN: ChessBoard.startFEN, moves: moves("1. f3 e5 2. g4 Qh4#"))
        XCTAssertTrue(trace.isBook(ply: 2), "the data set names Fool's Mate")
        XCTAssertEqual(Scoring.severity(.blunder, isBook: true), .blunder)
        XCTAssertNil(Scoring.severity(.mistake, isBook: true))
        XCTAssertNil(Scoring.severity(.inaccuracy, isBook: true))
        XCTAssertEqual(Scoring.severity(.mistake, isBook: false), .mistake)
    }

    func testAGameFromAnotherPositionHasNoBook() {
        let fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"
        let board = ChessBoard(fen: fen)!
        let move = board.move(fromSAN: "e4")!
        let trace = OpeningBook.shared.trace(startFEN: fen, moves: [move])
        XCTAssertEqual(trace.bookMoves, 0)
        XCTAssertNil(trace.opening)
    }

    func testTheDataSetIsReadColumnByColumn() {
        let book = OpeningBook(tsv: "eco\tname\tpgn\nB00\tTest Opening\t1. e4 a6\nB00\tBroken\t1. e5\n")
        let trace = book.trace(startFEN: ChessBoard.startFEN, moves: moves("1. e4 a6 2. d4"))
        XCTAssertEqual(trace.bookMoves, 2, "positions along a line are book even when unnamed")
        XCTAssertNil(trace.opening(afterPlies: 1))
        XCTAssertEqual(trace.opening(afterPlies: 2), Opening(eco: "B00", name: "Test Opening"))
        XCTAssertEqual(trace.opening?.family, "Test Opening")
    }
}
