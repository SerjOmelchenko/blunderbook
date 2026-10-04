//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation
import CryptoKit

/// Stable identity for a game and its contents.
///
/// The key is the provider UUID when one is returned and the canonical URL otherwise (§4), so
/// repeated imports of the same game never create a second row. The move hash covers the
/// starting position *and* the move sequence: a FEN alone is not an adequate identity, and a
/// changed PGN must invalidate a saved analysis.
enum GameIdentity {

    static func canonicalKey(uuid: String?, url: String) -> String {
        if let uuid, !uuid.isEmpty { return uuid }
        return canonicalURL(url)
    }

    static func canonicalURL(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func moveHash(startFEN: String, moves: [Move]) -> String {
        var input = startFEN
        input += "|"
        input += moves.map(\.uci).joined(separator: " ")
        return sha256(input)
    }

    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
