//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Failures are classified, never collapsed into "something went wrong": a 404 on a profile is
/// not evidence about privacy settings, and an unavailable month is not a missing player (§4).
enum ProviderError: LocalizedError, Equatable {
    case playerNotFound
    case archiveUnavailable
    case offline
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case malformedResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .playerNotFound: return "That player was not found on Chess.com."
        case .archiveUnavailable: return "One month of the archive is unavailable right now."
        case .offline: return "You appear to be offline."
        case .rateLimited: return "Chess.com is rate limiting requests."
        case .serverError(let code): return "Chess.com returned an error (\(code))."
        case .malformedResponse: return "The response could not be read."
        case .cancelled: return "The refresh was stopped."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .playerNotFound: return "Check the spelling. Your saved data is unchanged."
        case .archiveUnavailable: return "Other months were still downloaded. Try again later."
        case .offline: return "Cached games and saved reviews are still available."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Requests pause for about \(Int(retryAfter)) seconds." }
            return "Requests pause for a moment before trying again."
        case .serverError, .malformedResponse: return "Your downloaded games and reviews are unchanged."
        case .cancelled: return nil
        }
    }
}

struct ProviderProfile: Hashable {
    var providerID: String?
    var username: String
    var name: String?
    var avatarURL: String?
    var country: String?
    var title: String?
}

struct ProviderArchiveMonth: Hashable {
    var year: Int
    var month: Int
    var url: String
}

struct ProviderGame {
    var url: String
    var uuid: String?
    var pgn: String
    var endTime: Date
    var timeClass: String
    var timeControl: String
    var rules: String
    var rated: Bool
    var initialSetup: String?
    var whiteUsername: String
    var whiteRating: Int?
    var whiteResult: String
    var blackUsername: String
    var blackRating: Int?
    var blackResult: String
    var ecoURL: String?
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

    private let session: URLSession
    private let userAgent: String
    /// Set while the provider has asked us to back off.
    private(set) var rateLimitedUntil: Date?

    init(session: URLSession? = nil, appVersion: String = Bundle.main.appVersion) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: configuration)
        }
        // A descriptive User-Agent is what the provider asks for.
        userAgent = "ChessAnalyser/\(appVersion) (iOS local analysis app; contact: support@example.com)"
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
        return ProviderProfile(providerID: providerID,
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

        let (data, response) = try await get(url: url, headers: headers, allowNotModified: true)
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
        try await get(url: Self.baseURL.appendingPathComponent(path), headers: [:], allowNotModified: false)
    }

    /// Retries network and 5xx failures with jittered 2, 4, 8, 16, 32-second backoff, then stops
    /// this attempt. A manual Retry starts a fresh attempt (§4).
    private func get(url: URL, headers: [String: String], allowNotModified: Bool) async throws -> (Data, HTTPURLResponse) {
        let delays: [TimeInterval] = [2, 4, 8, 16, 32]
        var attempt = 0

        while true {
            if let rateLimitedUntil, rateLimitedUntil > Date() {
                throw ProviderError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSinceNow)
            }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }

                switch http.statusCode {
                case 200:
                    rateLimitedUntil = nil
                    return (data, http)
                case 304 where allowNotModified:
                    rateLimitedUntil = nil
                    return (data, http)
                case 404, 410:
                    throw allowNotModified ? ProviderError.archiveUnavailable : ProviderError.playerNotFound
                case 429:
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? 60)
                    throw ProviderError.rateLimited(retryAfter: retryAfter)
                case 500...599:
                    guard attempt < delays.count else { throw ProviderError.serverError(http.statusCode) }
                    try await backoff(delays[attempt]); attempt += 1
                default:
                    throw ProviderError.serverError(http.statusCode)
                }
            } catch let error as ProviderError {
                throw error
            } catch let error as URLError {
                if error.code == .cancelled { throw ProviderError.cancelled }
                if Self.offlineCodes.contains(error.code) { throw ProviderError.offline }
                guard attempt < delays.count else { throw ProviderError.offline }
                try await backoff(delays[attempt]); attempt += 1
            }
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost
    ]

    private func backoff(_ seconds: TimeInterval) async throws {
        // Jitter keeps several profiles from retrying in lockstep.
        let jittered = seconds * Double.random(in: 0.8...1.2)
        try? await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
        if Task.isCancelled { throw ProviderError.cancelled }
    }

    /// Trim, reject control characters and path separators, then percent-encode (§4).
    static func normalize(username: String) -> String? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        guard trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("?"), !trimmed.contains("#") else { return nil }
        guard trimmed.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    private static func encode(_ username: String) -> String {
        username.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
