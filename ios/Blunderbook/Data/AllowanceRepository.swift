//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The free plan. Analysing any single game you open is free and unlimited. Premium adds the
/// Mistakes tab, the two deepest review depths (`ReviewDepth.requiresPremium`) and any number
/// of tracked players.
enum FreePlan {
    /// How many players can be tracked without a subscription. A Chess.com and a Lichess account
    /// are two players. Players tracked before a limit applied are kept; only adding is blocked.
    static let maxPlayers = 1

    /// "one player", for sentences.
    static var playersDescription: String {
        maxPlayers == 1 ? "one player" : "up to \(maxPlayers) players"
    }
}

/// Which allowance paid for a queued job. Analyses are no longer charged, so new jobs always
/// record `.none`; the other cases remain only so rows written by earlier builds still decode.
enum AllowanceBucket: String, Codable {
    case window
    case daily
    case none
}
