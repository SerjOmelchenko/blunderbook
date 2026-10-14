//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

struct ProviderArchiveMonth: Hashable {
    var year: Int
    var month: Int
    var url: String
}

struct ArchiveResponse {
    var games: [ProviderGame]
    var etag: String?
    var lastModified: String?
    /// True when the server answered 304 and the cached month is still current.
    var notModified: Bool
}

/// Talks to the public Chess.com Published-Data API.
///
/// One request at a time, conditional where possible, with explicit handling for 429 and
/// `Retry-After`. No credentials are ever sent — every endpoint here is public (§4).
actor ChessComClient {
    static let baseURL = URL(string: "https://api.chess.com/pub")!

    private let transport: ProviderTransport

    init(session: URLSession? = nil) {
        transport = ProviderTransport(session: session, accept: "application/json")
    }

    // MARK: - Endpoints

    func profile(username: String) async throws -> ProviderProfile {
        let path = "player/\(Self.encode(username))"
        let (data, _) = try await get(path: path)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse
        }
        var providerID: String?
        if let identifier = object["player_id"] as? Int { providerID = String(identifier) }
        else if let identifier = object["player_id"] as? String { providerID = identifier }
        return ProviderProfile(provider: .chessCom,
                               providerID: providerID,
                               username: (object["username"] as? String) ?? username,
                               name: object["name"] as? String,
                               avatarURL: object["avatar"] as? String,
                               country: (object["country"] as? String).flatMap { $0.split(separator: "/").last.map(String.init) },
                               title: object["title"] as? String)
    }

    func archives(username: String) async throws -> [ProviderArchiveMonth] {
        let (data, _) = try await get(path: "player/\(Self.encode(username))/games/archives")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urls = object["archives"] as? [String] else {
            throw ProviderError.malformedResponse
        }
        return urls.compactMap { url in
            let parts = url.split(separator: "/")
            guard parts.count >= 2, let month = Int(parts[parts.count - 1]), let year = Int(parts[parts.count - 2]) else { return nil }
            return ProviderArchiveMonth(year: year, month: month, url: url)
        }.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    }

    /// Conditional month fetch. A 304 means the cached month is unchanged and no games are
    /// re-downloaded (§4).
    func games(month: ProviderArchiveMonth, etag: String?, lastModified: String?) async throws -> ArchiveResponse {
        guard let url = URL(string: month.url) else { throw ProviderError.malformedResponse }
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        if let lastModified { headers["If-Modified-Since"] = lastModified }

        let (data, response) = try await transport.get(url: url, headers: headers, allowNotModified: true,
                                                       notFound: .archiveUnavailable)
        if response.statusCode == 304 {
            return ArchiveResponse(games: [], etag: etag, lastModified: lastModified, notModified: true)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawGames = object["games"] as? [[String: Any]] else {
            throw ProviderError.malformedResponse
        }
        return ArchiveResponse(games: rawGames.compactMap(Self.game),
                               etag: response.value(forHTTPHeaderField: "ETag"),
                               lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                               notModified: false)
    }

    private static func game(_ object: [String: Any]) -> ProviderGame? {
        guard let url = object["url"] as? String,
              let pgn = object["pgn"] as? String,
              let endTime = object["end_time"] as? Int,
              let white = object["white"] as? [String: Any],
              let black = object["black"] as? [String: Any] else { return nil }
        return ProviderGame(url: url,
                            uuid: object["uuid"] as? String,
                            pgn: pgn,
                            endTime: Date(timeIntervalSince1970: TimeInterval(endTime)),
                            timeClass: (object["time_class"] as? String) ?? "",
                            timeControl: (object["time_control"] as? String) ?? "",
                            rules: (object["rules"] as? String) ?? "chess",
                            rated: (object["rated"] as? Bool) ?? false,
                            initialSetup: object["initial_setup"] as? String,
                            whiteUsername: (white["username"] as? String) ?? "",
                            whiteRating: white["rating"] as? Int,
                            whiteResult: (white["result"] as? String) ?? "",
                            blackUsername: (black["username"] as? String) ?? "",
                            blackRating: black["rating"] as? Int,
                            blackResult: (black["result"] as? String) ?? "",
                            ecoURL: object["eco"] as? String)
    }

    // MARK: - Transport

    private func get(path: String) async throws -> (Data, HTTPURLResponse) {
        try await transport.get(url: Self.baseURL.appendingPathComponent(path))
    }

    static func normalize(username: String) -> String? {
        Provider.chessCom.normalize(username: username)
    }

    private static func encode(_ username: String) -> String {
        username.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
    }
}
