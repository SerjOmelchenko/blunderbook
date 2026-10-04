//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

extension ChessBoard {

    // MARK: - Writing SAN

    /// Standard algebraic notation for a legal move in the current position.
    func san(for move: Move) -> String {
        guard let moving = piece(at: move.fromSquare) else { return move.uci }

        var text: String
        if isCastling(move) {
            text = Square.file(move.toSquare) == 6 ? "O-O" : "O-O-O"
        } else {
            let capture = isCapture(move)
            if moving.kind == .pawn {
                text = capture ? "\(fileCharacter(move.fromSquare))x" : ""
                text += Square.name(move.toSquare)
                if let promotion = move.promotion { text += "=\(promotion.letter)" }
            } else {
                text = moving.kind.letter + disambiguation(for: move, kind: moving.kind)
                if capture { text += "x" }
                text += Square.name(move.toSquare)
            }
        }

        makeMove(move)
        if isInCheck {
            text += hasLegalMove ? "+" : "#"
        }
        unmakeMove()
        return text
    }

    private func fileCharacter(_ square: Int) -> Character {
        Character(UnicodeScalar(UInt8(97 + Square.file(square))))
    }

    private func disambiguation(for move: Move, kind: PieceKind) -> String {
        let rivals = legalMoves().filter { candidate in
            candidate != move
                && candidate.toSquare == move.toSquare
                && piece(at: candidate.fromSquare)?.kind == kind
        }
        guard !rivals.isEmpty else { return "" }
        let sameFile = rivals.contains { Square.file($0.fromSquare) == Square.file(move.fromSquare) }
        let sameRank = rivals.contains { Square.rank($0.fromSquare) == Square.rank(move.fromSquare) }
        if !sameFile { return String(fileCharacter(move.fromSquare)) }
        if !sameRank { return String(Square.rank(move.fromSquare) + 1) }
        return Square.name(move.fromSquare)
    }

    // MARK: - Reading SAN

    /// Resolves a SAN token against the legal moves of the current position.
    /// Returns nil when the token is malformed or does not name a legal move.
    func move(fromSAN token: String) -> Move? {
        var text = token.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "0", with: "O")
        // Drop check, mate and annotation glyphs; they carry no disambiguation.
        text = text.filter { !"+#!?".contains($0) }
        guard !text.isEmpty else { return nil }

        let moves = legalMoves()

        if text == "O-O" || text == "e1g1" || text == "e8g8" {
            if let castle = moves.first(where: { isCastling($0) && Square.file($0.toSquare) == 6 }) { return castle }
        }
        if text == "O-O-O" {
            if let castle = moves.first(where: { isCastling($0) && Square.file($0.toSquare) == 2 }) { return castle }
        }
        if text.hasPrefix("O-O") { return nil }

        var characters = Array(text)

        var promotion: PieceKind?
        if let equalsIndex = characters.firstIndex(of: "=") {
            guard equalsIndex + 1 < characters.count, let kind = PieceKind.fromLetter(characters[equalsIndex + 1]) else { return nil }
            promotion = kind
            characters.removeSubrange(equalsIndex...)
        } else if characters.count >= 3, let last = characters.last, let kind = PieceKind.fromLetter(last),
                  kind != .pawn, kind != .king, last.isLowercase {
            // Trailing lower-case promotion letter, e.g. `e8q`.
            promotion = kind
            characters.removeLast()
        }

        var kind = PieceKind.pawn
        if let first = characters.first, first.isUppercase, let parsed = PieceKind.fromLetter(first) {
            kind = parsed
            characters.removeFirst()
        }

        characters.removeAll { $0 == "x" || $0 == "-" || $0 == ":" }
        guard characters.count >= 2 else { return nil }

        let destinationText = String(characters.suffix(2))
        guard let destination = Square.parse(destinationText) else { return nil }
        let hint = Array(characters.dropLast(2))

        var hintFile: Int?
        var hintRank: Int?
        for character in hint {
            if let ascii = character.asciiValue {
                if (97...104).contains(ascii) { hintFile = Int(ascii) - 97 }
                else if (49...56).contains(ascii) { hintRank = Int(ascii) - 49 }
                else { return nil }
            } else {
                return nil
            }
        }

        let candidates = moves.filter { candidate in
            guard candidate.toSquare == destination else { return false }
            guard piece(at: candidate.fromSquare)?.kind == kind else { return false }
            guard candidate.promotion == promotion else { return false }
            if let hintFile, Square.file(candidate.fromSquare) != hintFile { return false }
            if let hintRank, Square.rank(candidate.fromSquare) != hintRank { return false }
            return true
        }
        if candidates.count == 1 { return candidates[0] }
        // Some sources omit `=Q`; fall back to the queen promotion when that is unambiguous.
        if candidates.isEmpty, promotion == nil {
            let promotions = moves.filter {
                $0.toSquare == destination && $0.promotion == .queen
                    && piece(at: $0.fromSquare)?.kind == kind
                    && (hintFile == nil || Square.file($0.fromSquare) == hintFile!)
            }
            if promotions.count == 1 { return promotions[0] }
        }
        return nil
    }
}
