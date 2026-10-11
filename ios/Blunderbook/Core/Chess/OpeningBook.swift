//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A named opening line, such as "C50 Italian Game: Giuoco Piano".
struct Opening: Hashable {
    var eco: String
    var name: String

    /// The family before the colon: "Italian Game".
    var family: String {
        name.split(separator: ":", maxSplits: 1).first.map { String($0) } ?? name
    }
}

/// How a game's opening went: which of its first moves were book, and which named opening each
/// position had reached.
struct OpeningTrace: Equatable {
    /// How many of the game's first moves were book: every one of them reached a position on a
    /// known opening line, with no move off the book before it.
    var bookMoves = 0
    /// For each position, 0 being the start, the deepest named opening reached up to there. It
    /// stays at the last name once the game leaves the book.
    var openings: [Opening?] = []

    static let empty = OpeningTrace()

    /// Whether the move at `ply` (0 is White's first move) was a book move.
    func isBook(ply: Int) -> Bool { ply >= 0 && ply < bookMoves }

    /// The opening as of the position after `plies` moves.
    func opening(afterPlies plies: Int) -> Opening? {
        guard !openings.isEmpty else { return nil }
        return openings[min(max(0, plies), openings.count - 1)]
    }

    /// The opening the game ended up in: the deepest name it reached.
    var opening: Opening? { openings.last ?? nil }
}

/// The book of known opening moves: every position on every line of the Lichess chess-openings
/// data set (public domain), and the name of each line's final position. Positions are matched
/// by the board's Zobrist key, so a line reached by a different move order is still recognised.
///
/// The data set names traps too, such as Fool's Mate, so being in the book is no promise that a
/// move was good: a deep review still calls a book move a blunder when it is one.
///
/// Built once, on first use, from the bundled `Openings.tsv`; about 3,900 lines.
final class OpeningBook: @unchecked Sendable {
    static let shared = OpeningBook()

    private let positions: Set<UInt64>
    private let names: [UInt64: Opening]

    private convenience init() {
        let url = Bundle.main.url(forResource: "Openings", withExtension: "tsv")
        self.init(tsv: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }

    /// Reads the data set's three columns: ECO code, name, and the line as PGN movetext.
    init(tsv text: String) {
        var positions = Set<UInt64>()
        var names: [UInt64: Opening] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let parsed = PGNParser.parse(String(columns[2]))
            guard parsed.parseError == nil, !parsed.moves.isEmpty else { continue }
            let board = ChessBoard()
            for move in parsed.moves {
                board.makeMove(move)
                positions.insert(Self.key(board))
            }
            // The first line to name a position keeps it; the data set lists each position once.
            let key = Self.key(board)
            if names[key] == nil {
                names[key] = Opening(eco: String(columns[0]), name: String(columns[1]))
            }
        }
        self.positions = positions
        self.names = names
    }

    var isEmpty: Bool { positions.isEmpty }

    /// The position's key without its en-passant file. The board records one after every double
    /// pawn step, capture possible or not, so 1. c4 e6 2. d4 and 1. d4 e6 2. c4 would otherwise
    /// be different positions.
    private static func key(_ board: ChessBoard) -> UInt64 {
        guard board.enPassantSquare >= 0 else { return board.zobrist }
        return board.zobrist ^ Zobrist.table.enPassantFile[Square.file(board.enPassantSquare)]
    }

    /// Follows a game from the standard starting position. A game from any other position has
    /// no book.
    func trace(startFEN: String, moves: [Move]) -> OpeningTrace {
        // Move counters aside, the position must be the usual one.
        let isStandardStart = startFEN.split(separator: " ").prefix(4)
            == ChessBoard.startFEN.split(separator: " ").prefix(4)
        guard !moves.isEmpty, isStandardStart else {
            return OpeningTrace(bookMoves: 0, openings: Array(repeating: nil, count: moves.count + 1))
        }
        let board = ChessBoard()
        var trace = OpeningTrace(bookMoves: 0, openings: [nil])
        var current: Opening?
        var inBook = true
        for move in moves {
            board.makeMove(move)
            let key = Self.key(board)
            if inBook, positions.contains(key) {
                trace.bookMoves += 1
                if let name = names[key] { current = name }
            } else {
                inBook = false
            }
            trace.openings.append(current)
        }
        return trace
    }
}
