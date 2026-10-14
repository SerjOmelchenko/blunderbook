//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Failures are classified, never collapsed into "something went wrong": a 404 on a profile is
/// not evidence about privacy settings, and an unavailable month is not a missing player (§4).
/// The messages name no site: the screen showing one already says which player, and so which
/// site, it is about.
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
        case .playerNotFound: return "That player was not found."
        case .archiveUnavailable: return "Part of the game history is unavailable right now."
        case .offline: return "You appear to be offline."
        case .rateLimited: return "The site is limiting requests for now."
        case .serverError(let code): return "The site returned an error (\(code))."
        case .malformedResponse: return "The response could not be read."
        case .cancelled: return "The refresh was stopped."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .playerNotFound: return "Check the spelling. Your saved data is unchanged."
        case .archiveUnavailable: return "Other games were still downloaded. Try again later."
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
    var provider: Provider = .chessCom
    /// As stored on the player: Lichess identities carry a `lichess:` prefix.
    var providerID: String?
    var username: String
    var name: String?
    var avatarURL: String?
    var country: String?
    var title: String?
    /// Games the site says the player has finished, when it says; used to show import progress.
    var gameCount: Int?
    /// True when the player has correspondence games, which can finish long after they started.
    var playsCorrespondence = false
}

/// One downloaded game in Chess.com's vocabulary. Lichess games are translated into it as they
/// arrive, so both sites share one path into the database.
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

/// HTTP for one site. Each site gets one of these, shared by every player on it, so requests to
/// a site go one at a time and a rate limit from it pauses all of them.
///
/// No credentials are ever sent — every endpoint used is public (§4).
actor ProviderTransport {
    private let session: URLSession
    private let userAgent: String
    /// How long to pause after a 429 that did not say: Lichess asks for a full minute.
    private let defaultRateLimitPause: TimeInterval
    /// Set while the provider has asked us to back off.
    private(set) var rateLimitedUntil: Date?

    init(session: URLSession? = nil, accept: String, defaultRateLimitPause: TimeInterval = 60,
         appVersion: String = Bundle.main.appVersion) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 30
            configuration.httpAdditionalHeaders = ["Accept": accept]
            self.session = URLSession(configuration: configuration)
        }
        self.defaultRateLimitPause = defaultRateLimitPause
        // A descriptive User-Agent is what both sites ask for; Lichess refuses generic ones.
        userAgent = "Blunderbook/\(appVersion) (iOS local analysis app; contact: somelchenko.work@gmail.com)"
    }

    /// Retries network and 5xx failures with jittered 2, 4, 8, 16, 32-second backoff, then stops
    /// this attempt. A manual Retry starts a fresh attempt (§4).
    ///
    /// `notFound` is what a 404 or 410 means for this request: a missing player for a profile,
    /// an unavailable month for an archive.
    func get(url: URL, headers: [String: String] = [:], allowNotModified: Bool = false,
             notFound: ProviderError = .playerNotFound) async throws -> (Data, HTTPURLResponse) {
        try await withRetries {
            let (data, response) = try await self.session.data(for: self.request(url, headers))
            let http = try self.check(response, allowNotModified: allowNotModified, notFound: notFound)
            return (data, http)
        }
    }

    /// Opens a streamed response, such as Lichess's newline-delimited game export, and hands
    /// back its lines once the status is known to be good. Only opening the stream is retried:
    /// a stream that breaks part-way surfaces the error, and the caller keeps what it has read.
    func lines(url: URL, headers: [String: String] = [:],
               notFound: ProviderError = .playerNotFound) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        try await withRetries {
            let (bytes, response) = try await self.session.bytes(for: self.request(url, headers))
            _ = try self.check(response, allowNotModified: false, notFound: notFound)
            return bytes.lines
        }
    }

    /// Maps a failure while reading a stream that had opened, so it is classified like any other.
    static func classify(_ error: Error) -> ProviderError {
        if let error = error as? ProviderError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .offline
        }
        if error is CancellationError { return .cancelled }
        return .malformedResponse
    }

    // MARK: - Internals

    private func request(_ url: URL, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    private func check(_ response: URLResponse, allowNotModified: Bool,
                       notFound: ProviderError) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }
        switch http.statusCode {
        case 200:
            rateLimitedUntil = nil
            return http
        case 304 where allowNotModified:
            rateLimitedUntil = nil
            return http
        case 404, 410:
            throw notFound
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? defaultRateLimitPause)
            throw ProviderError.rateLimited(retryAfter: retryAfter ?? defaultRateLimitPause)
        case 500...599:
            throw ServerFailure(code: http.statusCode)
        default:
            throw ProviderError.serverError(http.statusCode)
        }
    }

    /// A 5xx, which is retried; it becomes `ProviderError.serverError` once retries run out.
    private struct ServerFailure: Error { var code: Int }

    private func withRetries<T>(_ operation: () async throws -> T) async throws -> T {
        let delays: [TimeInterval] = [2, 4, 8, 16, 32]
        var attempt = 0

        while true {
            if let rateLimitedUntil, rateLimitedUntil > Date() {
                throw ProviderError.rateLimited(retryAfter: rateLimitedUntil.timeIntervalSinceNow)
            }
            do {
                return try await operation()
            } catch let error as ProviderError {
                throw error
            } catch let failure as ServerFailure {
                guard attempt < delays.count else { throw ProviderError.serverError(failure.code) }
                try await backoff(delays[attempt]); attempt += 1
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
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}
