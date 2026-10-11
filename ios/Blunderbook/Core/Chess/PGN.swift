//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A parsed PGN game: header tags plus the main line, validated against the rules engine.
struct PGNGame {
    var tags: [String: String] = [:]
    var startFEN: String = ChessBoard.startFEN
    var moves: [Move] = []
    var sanMoves: [String] = []
    var result: String = "*"
    /// Set when the movetext stopped being legal. Preceding moves are still usable (§4:
    /// malformed games stay visible instead of being discarded).
    var parseError: String?

    var isValid: Bool { parseError == nil }
    var plyCount: Int { moves.count }

    subscript(tag key: String) -> String? { tags[key] }
}

enum PGNParser {

    /// Parses one game. Tag pairs are read first so `[SetUp]`/`[FEN]` can seed the board.
    static func parse(_ text: String) -> PGNGame {
        var game = PGNGame()
        let (tags, movetextStart) = parseTags(text)
        game.tags = tags

        if let fen = tags["FEN"], !fen.isEmpty, ChessBoard(fen: fen) != nil {
            game.startFEN = fen
        }
        guard let board = ChessBoard(fen: game.startFEN) else {
            game.parseError = "Unreadable starting position"
            return game
        }

        let tokens = tokenizeMovetext(text[movetextStart...])
        for token in tokens {
            switch token {
            case .result(let value):
                game.result = value
            case .san(let value):
                guard let move = board.move(fromSAN: value) else {
                    game.parseError = "Illegal or unreadable move: \(value)"
                    return game
                }
                game.sanMoves.append(board.san(for: move))
                game.moves.append(move)
                board.makeMove(move)
            }
        }
        if game.result == "*", let tagResult = tags["Result"] { game.result = tagResult }
        return game
    }

    // MARK: - Tags

    private static func parseTags(_ text: String) -> ([String: String], String.Index) {
        var tags: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            // Skip whitespace between tag pairs.
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex, text[index] == "[" else { break }

            var cursor = text.index(after: index)
            var name = ""
            while cursor < text.endIndex, !text[cursor].isWhitespace, text[cursor] != "\"" {
                name.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            while cursor < text.endIndex, text[cursor] != "\"" { cursor = text.index(after: cursor) }
            guard cursor < text.endIndex else { break }
            cursor = text.index(after: cursor)

            var value = ""
            var escaped = false
            while cursor < text.endIndex {
                let character = text[cursor]
                if escaped {
                    value.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                } else {
                    value.append(character)
                }
                cursor = text.index(after: cursor)
            }
            while cursor < text.endIndex, text[cursor] != "]" { cursor = text.index(after: cursor) }
            if cursor < text.endIndex { cursor = text.index(after: cursor) }

            if !name.isEmpty { tags[name] = value }
            index = cursor
        }
        return (tags, index)
    }

    // MARK: - Movetext

    private enum Token {
        case san(String)
        case result(String)
    }

    private static let resultTokens: Set<String> = ["1-0", "0-1", "1/2-1/2", "*"]

    private static func tokenizeMovetext(_ text: Substring) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var variationDepth = 0
        var index = text.startIndex

        func flush() {
            defer { current = "" }
            guard !current.isEmpty, variationDepth == 0 else { return }
            if resultTokens.contains(current) {
                tokens.append(.result(current))
                return
            }
            // Strip a leading move number such as `12.` or `12...`.
            var token = current
            if let dotIndex = token.lastIndex(of: "."), token[token.startIndex..<dotIndex].allSatisfy({ $0.isNumber || $0 == "." }) {
                token = String(token[token.index(after: dotIndex)...])
            }
            guard !token.isEmpty, !token.allSatisfy({ $0.isNumber }) else { return }
            if token.hasPrefix("$") { return }
            tokens.append(.san(token))
        }

        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "{":
                flush()
                while index < text.endIndex, text[index] != "}" { index = text.index(after: index) }
            case ";":
                flush()
                while index < text.endIndex, !text[index].isNewline { index = text.index(after: index) }
            case "(":
                flush()
                variationDepth += 1
            case ")":
                current = ""
                variationDepth = max(0, variationDepth - 1)
            case "<", ">":
                flush()
            default:
                if character.isWhitespace {
                    flush()
                } else {
                    current.append(character)
                }
            }
            if index < text.endIndex { index = text.index(after: index) }
        }
        flush()
        return tokens
    }
}
