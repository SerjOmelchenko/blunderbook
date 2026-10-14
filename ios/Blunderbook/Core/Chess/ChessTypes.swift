//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

// MARK: - Colors and pieces

enum PieceColor: Int, Codable, Hashable, CaseIterable {
    case white = 0
    case black = 1

    var opposite: PieceColor { self == .white ? .black : .white }
    /// +1 for white, -1 for black. Used by the board's internal Int8 encoding.
    var sign: Int8 { self == .white ? 1 : -1 }
    var name: String { self == .white ? "White" : "Black" }
}

enum PieceKind: Int, Codable, Hashable, CaseIterable {
    case pawn = 1, knight, bishop, rook, queen, king

    var letter: String {
        switch self {
        case .pawn: return ""
        case .knight: return "N"
        case .bishop: return "B"
        case .rook: return "R"
        case .queen: return "Q"
        case .king: return "K"
        }
    }

    /// Material weight used by §5 consequence templates (pawn 1, N/B 3, R 5, Q 9).
    var materialValue: Int {
        switch self {
        case .pawn: return 1
        case .knight, .bishop: return 3
        case .rook: return 5
        case .queen: return 9
        case .king: return 0
        }
    }

    /// Phase weight used by §5 (minor 1, rook 2, queen 4; pawns and kings excluded).
    var phaseWeight: Int {
        switch self {
        case .knight, .bishop: return 1
        case .rook: return 2
        case .queen: return 4
        case .pawn, .king: return 0
        }
    }

    static func fromLetter(_ character: Character) -> PieceKind? {
        switch character {
        case "P", "p": return .pawn
        case "N", "n": return .knight
        case "B", "b": return .bishop
        case "R", "r": return .rook
        case "Q", "q": return .queen
        case "K", "k": return .king
        default: return nil
        }
    }
}

struct Piece: Hashable, Codable {
    var color: PieceColor
    var kind: PieceKind

    var fenCharacter: Character {
        let base: Character
        switch kind {
        case .pawn: base = "p"
        case .knight: base = "n"
        case .bishop: base = "b"
        case .rook: base = "r"
        case .queen: base = "q"
        case .king: base = "k"
        }
        return color == .white ? Character(String(base).uppercased()) : base
    }

    /// Asset-catalogue name of this piece's artwork (the cburnett set, see NOTICE.md).
    var artworkName: String {
        let colour = self.color == .white ? "w" : "b"
        let letter: String
        switch kind {
        case .king: letter = "K"
        case .queen: letter = "Q"
        case .rook: letter = "R"
        case .bishop: letter = "B"
        case .knight: letter = "N"
        case .pawn: letter = "P"
        }
        return "piece-\(colour)\(letter)"
    }
}

// MARK: - Squares

/// Square indices run a1 = 0 … h1 = 7, a2 = 8 … h8 = 63.
enum Square {
    static func make(file: Int, rank: Int) -> Int { rank * 8 + file }
    static func file(_ square: Int) -> Int { square & 7 }
    static func rank(_ square: Int) -> Int { square >> 3 }

    static func name(_ square: Int) -> String {
        guard (0..<64).contains(square) else { return "-" }
        let fileCharacter = Character(UnicodeScalar(UInt8(97 + file(square))))
        return "\(fileCharacter)\(rank(square) + 1)"
    }

    static func parse(_ text: some StringProtocol) -> Int? {
        guard text.count == 2 else { return nil }
        let characters = Array(text)
        guard let fileScalar = characters[0].asciiValue, let rankScalar = characters[1].asciiValue else { return nil }
        let file = Int(fileScalar) - 97
        let rank = Int(rankScalar) - 49
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return make(file: file, rank: rank)
    }

    /// Light squares are the ones where file and rank have the same parity.
    static func isLight(_ square: Int) -> Bool { (file(square) + rank(square)) % 2 == 1 }
}

// MARK: - Castling

struct CastlingRights: OptionSet, Hashable {
    let rawValue: UInt8
    static let whiteKing = CastlingRights(rawValue: 1)
    static let whiteQueen = CastlingRights(rawValue: 2)
    static let blackKing = CastlingRights(rawValue: 4)
    static let blackQueen = CastlingRights(rawValue: 8)
    static let all: CastlingRights = [.whiteKing, .whiteQueen, .blackKing, .blackQueen]

    var fenText: String {
        if isEmpty { return "-" }
        var text = ""
        if contains(.whiteKing) { text += "K" }
        if contains(.whiteQueen) { text += "Q" }
        if contains(.blackKing) { text += "k" }
        if contains(.blackQueen) { text += "q" }
        return text
    }
}

// MARK: - Moves

struct Move: Hashable, Codable {
    var from: UInt8
    var to: UInt8
    var promotion: PieceKind?

    init(from: Int, to: Int, promotion: PieceKind? = nil) {
        self.from = UInt8(from)
        self.to = UInt8(to)
        self.promotion = promotion
    }

    var fromSquare: Int { Int(from) }
    var toSquare: Int { Int(to) }

    /// Long algebraic (UCI) form, e.g. `e2e4`, `e7e8q`.
    var uci: String {
        var text = Square.name(fromSquare) + Square.name(toSquare)
        if let promotion { text += promotion.letter.lowercased() }
        return text
    }

    static func fromUCI(_ text: some StringProtocol) -> Move? {
        guard text.count == 4 || text.count == 5 else { return nil }
        let characters = Array(text)
        guard let from = Square.parse(String(characters[0...1])),
              let to = Square.parse(String(characters[2...3])) else { return nil }
        var promotion: PieceKind?
        if characters.count == 5 {
            guard let kind = PieceKind.fromLetter(characters[4]), kind != .pawn, kind != .king else { return nil }
            promotion = kind
        }
        return Move(from: from, to: to, promotion: promotion)
    }
}

// MARK: - Terminal states

enum GameTerminal: String, Codable, Hashable {
    case checkmate
    case stalemate
    case insufficientMaterial
    case seventyFiveMoveRule
    case fivefoldRepetition

    var isDraw: Bool { self != .checkmate }

    var label: String {
        switch self {
        case .checkmate: return "Checkmate"
        case .stalemate: return "Stalemate"
        case .insufficientMaterial: return "Insufficient material"
        case .seventyFiveMoveRule: return "Seventy-five move rule"
        case .fivefoldRepetition: return "Fivefold repetition"
        }
    }
}
