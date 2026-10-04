//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// The free plan. Analysing any single game is free and unlimited; analysing a whole history in
/// one go ("Analyse all games") is Premium. The only other limit is how many players are tracked.
enum FreePlan {
    /// How many players can be tracked without a subscription.
    static let maxPlayers = 3
}

/// Which allowance paid for a queued job. Analyses are no longer charged, so new jobs always
/// record `.none`; the other cases remain only so rows written by earlier builds still decode.
enum AllowanceBucket: String, Codable {
    case window
    case daily
    case none
}
