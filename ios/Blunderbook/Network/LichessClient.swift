//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A window of a Lichess game export. Lichess filters `since` and `until` on when a game
/// started, in milliseconds, and streams the newest game first.
struct LichessExportRequest: Equatable {
    var since: Int?
    var until: Int?
    var max: Int?
    /// Lichess perf types to include; the default is every class this app supports, so
    /// variants and UltraBullet are never downloaded only to be dropped.
    var perfTypes = LichessClient.supportedPerfTypes
}

/// One game from the export: the game in the shared vocabulary, or nil when the app does not
/// support it, plus when it started, which is what the export's cursors are measured in.
struct LichessExportedGame {
    var game: ProviderGame?
    var createdAt: Int
}

/// Talks to the public Lichess API.
///
/// Lichess asks for one request at a time and a full minute's pause after a 429. Game history
/// is a single newline-delimited stream rather than monthly archives. No credentials are ever
/// sent — every endpoint here is public (§4).
actor LichessClient {
    static let baseURL = URL(string: "https://lichess.org")!
    static let supportedPerfTypes = ["bullet", "blitz", "rapid", "classical", "correspondence"]
    /// Prefix that keeps a Lichess identity from ever matching a Chess.com player ID.
    static let identityPrefix = "lichess:"

    private let transport: ProviderTransport

    init(session: URLSession? = nil) {
        transport = ProviderTransport(session: session, accept: "application/json")
    }

    // MARK: - Endpoints

    func profile(username: String) async throws -> ProviderProfile {
        let url = Self.baseURL.appendingPathComponent("api/user/\(Self.encode(username))")
        let (data, _) = try await transport.get(url: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse
        }
        return try Self.profile(object)
    }

    /// Streams a window of the player's finished games, newest first. Each line is handed to
    /// `receive` as it arrives, so a stream that breaks part-way keeps what was read.
    func export(username: String, request: LichessExportRequest,
                receive: (LichessExportedGame) throws -> Void) async throws {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("api/games/user/\(Self.encode(username))"),
                                       resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "finished", value: "true"),
                     URLQueryItem(name: "opening", value: "true"),
                     // Each move's remaining clock as a `[%clk]` comment, for the review's times.
                     URLQueryItem(name: "clocks", value: "true"),
                     URLQueryItem(name: "pgnInJson", value: "true"),
                     URLQueryItem(name: "perfType", value: request.perfTypes.joined(separator: ","))]
        if let since = request.since { query.append(URLQueryItem(name: "since", value: String(since))) }
        if let until = request.until { query.append(URLQueryItem(name: "until", value: String(until))) }
        if let max = request.max { query.append(URLQueryItem(name: "max", value: String(max))) }
        components.queryItems = query
        guard let url = components.url else { throw ProviderError.malformedResponse }

        let lines = try await transport.lines(url: url, headers: ["Accept": "application/x-ndjson"])
        do {
            for try await line in lines {
                if Task.isCancelled { throw ProviderError.cancelled }
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let exported = Self.exportedGame(object) else { continue }
                try receive(exported)
            }
        } catch {
            throw ProviderTransport.classify(error)
        }
    }

    // MARK: - Mapping

    static func profile(_ object: [String: Any]) throws -> ProviderProfile {
        guard let id = object["id"] as? String else { throw ProviderError.malformedResponse }
        // A closed account still has its games, but it can no longer be followed (§4).
        if (object["disabled"] as? Bool) == true { throw ProviderError.playerNotFound }
        let details = object["profile"] as? [String: Any]
        let count = object["count"] as? [String: Any]
        let correspondence = (object["perfs"] as? [String: Any])?["correspondence"] as? [String: Any]
        return ProviderProfile(provider: .lichess,
                               providerID: identityPrefix + id,
                               username: (object["username"] as? String) ?? id,
                               name: details?["realName"] as? String,
                               avatarURL: nil,
                               country: details?["flag"] as? String,
                               title: object["title"] as? String,
                               gameCount: count?["all"] as? Int,
                               playsCorrespondence: ((correspondence?["games"] as? Int) ?? 0) > 0)
    }

    /// Lichess reports how a game ended once, with the winner's colour; the app stores Chess.com's
    /// per-side result codes, so each side's code is derived here. Games that never really
    /// happened (aborted, never started) have no start time worth a cursor and are dropped.
    static func exportedGame(_ object: [String: Any]) -> LichessExportedGame? {
        guard let id = object["id"] as? String,
              let createdAt = (object["createdAt"] as? NSNumber)?.intValue else { return nil }
        return LichessExportedGame(game: game(object, id: id), createdAt: createdAt)
    }

    private static func game(_ object: [String: Any], id: String) -> ProviderGame? {
        guard let status = object["status"] as? String,
              let results = results(status: status, winner: object["winner"] as? String),
              let pgn = object["pgn"] as? String,
              let players = object["players"] as? [String: Any],
              let white = players["white"] as? [String: Any],
              let black = players["black"] as? [String: Any] else { return nil }
        let variant = (object["variant"] as? String) ?? "standard"
        let speed = (object["speed"] as? String) ?? ""
        let endMilliseconds = (object["lastMoveAt"] as? NSNumber)?.doubleValue
            ?? (object["createdAt"] as? NSNumber)?.doubleValue ?? 0

        return ProviderGame(url: "https://lichess.org/\(id)",
                            // Lichess game IDs are case-sensitive; the canonical-URL fallback
                            // lowercases, so the key is set here with its case intact.
                            uuid: identityPrefix + id,
                            pgn: pgn,
                            endTime: Date(timeIntervalSince1970: endMilliseconds / 1000),
                            timeClass: timeClass(speed: speed),
                            timeControl: timeControl(object),
                            // Only standard chess maps onto the app's "chess" rules; anything else,
                            // including games from a set-up position, is left unsupported.
                            rules: variant == "standard" ? "chess" : variant,
                            rated: (object["rated"] as? Bool) ?? false,
                            initialSetup: object["initialFen"] as? String,
                            whiteUsername: name(white),
                            whiteRating: white["rating"] as? Int,
                            whiteResult: results.white,
                            blackUsername: name(black),
                            blackRating: black["rating"] as? Int,
                            blackResult: results.black,
                            ecoURL: nil)
    }

    /// Chess.com result codes for each side, or nil for a game that did not finish.
    static func results(status: String, winner: String?) -> (white: String, black: String)? {
        let loserCode: String
        switch status {
        case "mate": loserCode = "checkmated"
        case "resign": loserCode = "resigned"
        case "outoftime":
            // Out of time with no winner: the other side could not have mated.
            guard winner != nil else { return ("timevsinsufficient", "timevsinsufficient") }
            loserCode = "timeout"
        case "timeout": loserCode = "abandoned" // the loser left and the winner claimed the game
        case "cheat": loserCode = "lose"
        case "draw": return ("draw", "draw")
        case "stalemate": return ("stalemate", "stalemate")
        case "insufficientMaterialClaim": return ("insufficient", "insufficient")
        case "created", "started", "aborted", "noStart", "unknownFinish": return nil
        default:
            guard winner != nil else { return ("draw", "draw") }
            loserCode = "lose"
        }
        switch winner {
        case "white": return ("win", loserCode)
        case "black": return (loserCode, "win")
        default: return nil
        }
    }

    /// The app's time classes; UltraBullet has none and the game is not stored.
    static func timeClass(speed: String) -> String {
        switch speed {
        case "correspondence": return TimeClass.daily.rawValue
        default: return speed
        }
    }

    /// In Chess.com's format, which the app already displays: `180`, `180+2`, or `1/<seconds>`
    /// per move for correspondence.
    static func timeControl(_ object: [String: Any]) -> String {
        if let clock = object["clock"] as? [String: Any], let initial = clock["initial"] as? Int {
            let increment = (clock["increment"] as? Int) ?? 0
            return increment > 0 ? "\(initial)+\(increment)" : "\(initial)"
        }
        if let days = object["daysPerTurn"] as? Int { return "1/\(days * 86_400)" }
        return "-"
    }

    /// The account name, or what Lichess shows for a side with no account.
    private static func name(_ side: [String: Any]) -> String {
        if let user = side["user"] as? [String: Any], let name = user["name"] as? String { return name }
        if let level = side["aiLevel"] as? Int { return "Stockfish level \(level)" }
        return "Anonymous"
    }

    private static func encode(_ username: String) -> String {
        username.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
    }
}
