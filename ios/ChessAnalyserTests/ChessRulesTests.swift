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

final class ChessRulesTests: XCTestCase {

    private func perft(_ board: ChessBoard, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        var buffer: [Move] = []
        board.generatePseudoLegalMoves(into: &buffer)
        var total = 0
        for move in buffer {
            let mover = board.sideToMove
            board.makeMove(move)
            if !board.isInCheck(mover) {
                total += depth == 1 ? 1 : perft(board, depth - 1)
            }
            board.unmakeMove()
        }
        return total
    }

    func testPerftStartPosition() {
        let board = ChessBoard()
        XCTAssertEqual(perft(board, 1), 20)
        XCTAssertEqual(perft(board, 2), 400)
        XCTAssertEqual(perft(board, 3), 8_902)
        XCTAssertEqual(perft(board, 4), 197_281)
    }

    func testPerftKiwipete() {
        let board = ChessBoard(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")!
        XCTAssertEqual(perft(board, 1), 48)
        XCTAssertEqual(perft(board, 2), 2_039)
        XCTAssertEqual(perft(board, 3), 97_862)
    }

    func testPerftEnPassantAndPromotionPositions() {
        let endgame = ChessBoard(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")!
        XCTAssertEqual(perft(endgame, 4), 43_238)
        let promotions = ChessBoard(fen: "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")!
        XCTAssertEqual(perft(promotions, 3), 9_467)
    }

    func testFENRoundTrip() {
        let fens = [
            ChessBoard.startFEN,
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "8/8/8/3pP3/8/8/8/K6k w - d6 0 2"
        ]
        for fen in fens {
            XCTAssertEqual(ChessBoard(fen: fen)?.fen, fen)
        }
    }

    func testCastlingThroughCheckIsRejected() {
        let board = ChessBoard(fen: "4k3/8/8/8/8/8/5r2/4K2R w K - 0 1")!
        XCTAssertNil(board.move(fromSAN: "O-O"), "castling across an attacked square must be illegal")
    }

    func testLegalCastlingIsAccepted() {
        let board = ChessBoard(fen: "4k3/8/8/8/8/8/8/4K2R w K - 0 1")!
        let castle = board.move(fromSAN: "O-O")
        XCTAssertNotNil(castle)
        board.makeMove(castle!)
        XCTAssertEqual(board.piece(at: Square.parse("g1")!)?.kind, .king)
        XCTAssertEqual(board.piece(at: Square.parse("f1")!)?.kind, .rook)
        board.unmakeMove()
        XCTAssertEqual(board.fen, "4k3/8/8/8/8/8/8/4K2R w K - 0 1")
    }

    func testEnPassantCapture() {
        let board = ChessBoard(fen: "8/8/8/3pP3/8/8/8/K6k w - d6 0 2")!
        let capture = board.move(fromSAN: "exd6")
        XCTAssertNotNil(capture)
        board.makeMove(capture!)
        XCTAssertNil(board.piece(at: Square.parse("d5")!), "the captured pawn must leave the board")
    }

    func testUnderpromotion() {
        let board = ChessBoard(fen: "8/P7/8/8/8/8/8/K6k w - - 0 1")!
        let knight = board.move(fromSAN: "a8=N")
        XCTAssertEqual(knight?.promotion, .knight)
        XCTAssertEqual(board.san(for: knight!), "a8=N")
    }

    func testDisambiguation() {
        let board = ChessBoard(fen: "8/8/8/8/8/2N1N3/8/K6k w - - 0 1")!
        let move = Move(from: Square.parse("c3")!, to: Square.parse("d5")!)
        XCTAssertEqual(board.san(for: move), "Ncd5")
    }

    func testTerminalStates() {
        XCTAssertEqual(ChessBoard(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")!.terminalState(), .stalemate)
        XCTAssertEqual(ChessBoard(fen: "8/8/8/4k3/8/8/8/4KB2 w - - 0 1")!.terminalState(), .insufficientMaterial)

        let mate = ChessBoard()
        for san in ["f3", "e5", "g4", "Qh4#"] {
            mate.makeMove(mate.move(fromSAN: san)!)
        }
        XCTAssertEqual(mate.terminalState(), .checkmate)
    }

    func testRepetitionCounting() {
        let board = ChessBoard()
        for san in ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8"] {
            board.makeMove(board.move(fromSAN: san)!)
        }
        XCTAssertGreaterThanOrEqual(board.repetitionCount(), 3)
    }

    func testPGNWithClockCommentsAndVariations() {
        let game = PGNParser.parse("""
            [Event "Live Chess"]
            [Result "0-1"]
            [TimeControl "600"]

            1. e4 {[%clk 0:09:58.9]} e5 {[%clk 0:09:57.3]} 2. Ke2!? $6 (2. Nf3 Nc6) Qh4 0-1
            """)
        XCTAssertNil(game.parseError)
        XCTAssertEqual(game.sanMoves, ["e4", "e5", "Ke2", "Qh4"])
        XCTAssertEqual(game.tags["TimeControl"], "600")
        XCTAssertEqual(game.result, "0-1")
    }

    func testZeroMoveGameParses() {
        let game = PGNParser.parse("[Event \"x\"]\n[Result \"1-0\"]\n\n1-0")
        XCTAssertNil(game.parseError)
        XCTAssertTrue(game.moves.isEmpty)
    }

    func testMalformedMovetextKeepsLegalPrefix() {
        let game = PGNParser.parse("[Event \"x\"]\n\n1. e4 e5 2. Qz9 Nf6")
        XCTAssertNotNil(game.parseError)
        XCTAssertEqual(game.moves.count, 2, "moves before the bad token stay usable")
    }

    func testSANRoundTripOverAFullGame() {
        let pgn = """
            [Event "Test"]

            1.e4 d6 2.d4 Nf6 3.Nc3 g6 4.Be3 Bg7 5.Qd2 c6 6.f3 b5 7.Nge2 Nbd7 8.Bh6 Bxh6
            9.Qxh6 Bb7 10.a3 e5 11.O-O-O Qe7 12.Kb1 a6 13.Nc1 O-O-O 14.Nb3 exd4 15.Rxd4 c5 1-0
            """
        let game = PGNParser.parse(pgn)
        XCTAssertNil(game.parseError)
        XCTAssertEqual(game.moves.count, 30)

        let board = ChessBoard(fen: game.startFEN)!
        for (index, move) in game.moves.enumerated() {
            XCTAssertEqual(board.san(for: move), game.sanMoves[index])
            board.makeMove(move)
        }
        for _ in game.moves { board.unmakeMove() }
        XCTAssertEqual(board.fen, game.startFEN, "unmaking every move must restore the start position")
    }
}

final class ProviderMappingTests: XCTestCase {

    func testOpeningSlugsKeepOnlyTheOpeningName() {
        // Chess.com appends the defining moves to its opening slugs.
        XCTAssertEqual(ArchiveSyncService.openingName(fromSlug: "Sicilian-Defense-Katalimov-Variation...4.Nxd4-Bb7-5.Nc3"),
                       "Sicilian Defense Katalimov Variation")
        XCTAssertEqual(ArchiveSyncService.openingName(fromSlug: "Birds-Opening-Froms-Gambit-2.fxe5-d6-3.Nf3-dxe5"),
                       "Birds Opening Froms Gambit")
        XCTAssertEqual(ArchiveSyncService.openingName(fromSlug: "Queens-Gambit-Declined"), "Queens Gambit Declined")
        XCTAssertNil(ArchiveSyncService.openingName(fromSlug: "2.fxe5"))
    }

    func testOpeningMetadataPrefersTheTagAndFallsBackHonestly() {
        XCTAssertEqual(ArchiveSyncService.openingName(tags: ["Opening": "Ruy Lopez"], ecoURL: nil), "Ruy Lopez")
        XCTAssertEqual(ArchiveSyncService.openingName(tags: ["ECOUrl": "https://www.chess.com/openings/Kings-Gambit"],
                                                      ecoURL: nil), "Kings Gambit")
        XCTAssertEqual(ArchiveSyncService.openingName(tags: ["ECO": "B20"], ecoURL: nil), "B20")
        XCTAssertNil(ArchiveSyncService.openingName(tags: [:], ecoURL: nil),
                     "absent metadata stays Unknown rather than being guessed")
    }

    func testUsernameNormalisationRejectsPathsAndControlCharacters() {
        XCTAssertEqual(ChessComClient.normalize(username: "  MagnusCarlsen "), "MagnusCarlsen")
        for bad in ["", "   ", "a/b", "http://chess.com/x", "name?x", "a\u{0}b", String(repeating: "x", count: 80)] {
            XCTAssertNil(ChessComClient.normalize(username: bad), "should reject \(bad.debugDescription)")
        }
    }

    func testResultCodesNormaliseToOutcomes() {
        XCTAssertEqual(ResultCodes.outcome(for: "win"), .win)
        XCTAssertEqual(ResultCodes.outcome(for: "timeout"), .loss)
        XCTAssertEqual(ResultCodes.outcome(for: "repetition"), .draw)
        XCTAssertEqual(ResultCodes.outcome(for: "timevsinsufficient"), .draw)
        XCTAssertEqual(ResultCodes.outcome(for: "somethingnew"), .unknown,
                       "an unrecognised code stays Unknown rather than being forced into a bucket")
    }

    func testUnsupportedGamesNeverBecomeRecords() {
        let variant = ProviderGame(url: "https://example.com/1", uuid: "1",
                                   pgn: "[Event \"x\"]\n\n1. e4 e5 1-0",
                                   endTime: Date(), timeClass: "blitz", timeControl: "180",
                                   rules: "chess960", rated: true, initialSetup: nil,
                                   whiteUsername: "a", whiteRating: 1, whiteResult: "win",
                                   blackUsername: "b", blackRating: 1, blackResult: "checkmated",
                                   ecoURL: nil)
        XCTAssertTrue(ArchiveSyncService.records(from: [variant]).isEmpty)

        let unknownClass = ProviderGame(url: "https://example.com/2", uuid: "2",
                                        pgn: "[Event \"x\"]\n\n1. e4 e5 1-0",
                                        endTime: Date(), timeClass: "puzzlerush", timeControl: "180",
                                        rules: "chess", rated: true, initialSetup: nil,
                                        whiteUsername: "a", whiteRating: 1, whiteResult: "win",
                                        blackUsername: "b", blackRating: 1, blackResult: "checkmated",
                                        ecoURL: nil)
        XCTAssertTrue(ArchiveSyncService.records(from: [unknownClass]).isEmpty)
    }
}

/// The development fixtures are real games shown on a real board, so they have to be legal.
/// A silently illegal fixture reads as an app bug when the review screen refuses to analyse it.
final class DevelopmentFixtureTests: XCTestCase {

    func testEveryFixtureIsALegalGame() {
        XCTAssertFalse(DevelopmentSeed.fixtures.isEmpty)
        for (index, fixture) in DevelopmentSeed.fixtures.enumerated() {
            let game = PGNParser.parse(fixture.pgn)
            XCTAssertNil(game.parseError,
                         "fixture \(index) is not legal: \(game.parseError ?? "") — parsed \(game.moves.count) plies")
            XCTAssertFalse(game.moves.isEmpty, "fixture \(index) has no moves")

            // And the move list has to replay cleanly onto a board.
            let board = ChessBoard(fen: game.startFEN)!
            for move in game.moves {
                XCTAssertTrue(board.isLegalMove(move),
                              "fixture \(index): \(move.uci) is not legal in \(board.fen)")
                board.makeMove(move)
            }
        }
    }

    func testFixturesDeclareAResultThatMatchesTheirNotation() {
        for (index, fixture) in DevelopmentSeed.fixtures.enumerated() {
            let game = PGNParser.parse(fixture.pgn)
            XCTAssertTrue(["1-0", "0-1", "1/2-1/2"].contains(game.result),
                          "fixture \(index) has result \(game.result)")
        }
    }
}
