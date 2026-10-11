//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Pre-computed geometry used by move generation and attack detection.
/// Everything is expressed as explicit destination lists so the generator never has to
/// guard against board wrap-around by hand.
enum ChessTables {
    /// (fileDelta, rankDelta) for the eight sliding directions. 0…3 are rook rays, 4…7 bishop rays.
    static let directions: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]
    static let rookDirections = 0..<4
    static let bishopDirections = 4..<8

    /// `rays[direction][square]` lists the squares outward from `square`, nearest first.
    static let rays: [[[Int]]] = {
        var table = [[[Int]]](repeating: [[Int]](repeating: [], count: 64), count: directions.count)
        for (index, delta) in directions.enumerated() {
            for square in 0..<64 {
                var file = Square.file(square) + delta.0
                var rank = Square.rank(square) + delta.1
                var line: [Int] = []
                while (0..<8).contains(file), (0..<8).contains(rank) {
                    line.append(Square.make(file: file, rank: rank))
                    file += delta.0
                    rank += delta.1
                }
                table[index][square] = line
            }
        }
        return table
    }()

    static let knightTargets: [[Int]] = targets(for: [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)])
    static let kingTargets: [[Int]] = targets(for: [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)])

    /// Squares a pawn of the given colour attacks from `square`.
    static let pawnAttacks: [[[Int]]] = {
        var table = [[[Int]]](repeating: [[Int]](repeating: [], count: 64), count: 2)
        for color in [PieceColor.white, PieceColor.black] {
            let forward = color == .white ? 1 : -1
            for square in 0..<64 {
                var squares: [Int] = []
                for fileDelta in [-1, 1] {
                    let file = Square.file(square) + fileDelta
                    let rank = Square.rank(square) + forward
                    if (0..<8).contains(file), (0..<8).contains(rank) {
                        squares.append(Square.make(file: file, rank: rank))
                    }
                }
                table[color.rawValue][square] = squares
            }
        }
        return table
    }()

    private static func targets(for deltas: [(Int, Int)]) -> [[Int]] {
        var table = [[Int]](repeating: [], count: 64)
        for square in 0..<64 {
            var squares: [Int] = []
            for delta in deltas {
                let file = Square.file(square) + delta.0
                let rank = Square.rank(square) + delta.1
                if (0..<8).contains(file), (0..<8).contains(rank) {
                    squares.append(Square.make(file: file, rank: rank))
                }
            }
            table[square] = squares
        }
        return table
    }
}

/// Deterministic Zobrist keys. One fixed seed, generated in a single pass, so transposition
/// entries and repetition keys are reproducible between launches and between devices.
struct ZobristKeys {
    /// `pieces[pieceIndex][square]` where pieceIndex is `(kind - 1) + (color == .black ? 6 : 0)`.
    let pieces: [[UInt64]]
    let blackToMove: UInt64
    let castling: [UInt64]
    let enPassantFile: [UInt64]

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        var state = seed
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        pieces = (0..<12).map { _ in (0..<64).map { _ in next() } }
        blackToMove = next()
        castling = (0..<16).map { _ in next() }
        enPassantFile = (0..<8).map { _ in next() }
    }
}

enum Zobrist {
    static let table = ZobristKeys()

    static func index(color: PieceColor, kind: PieceKind) -> Int {
        (kind.rawValue - 1) + (color == .black ? 6 : 0)
    }
}
