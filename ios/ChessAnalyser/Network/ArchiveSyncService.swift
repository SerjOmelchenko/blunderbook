//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

struct RefreshProgress: Hashable {
    var monthsCompleted = 0
    var monthsTotal = 0
    var gamesStored = 0
    var eligibleKnown = 0
    var currentMonthLabel: String?
    var isFinished = false
}

struct RefreshOutcome {
    var status: PlayerSyncStatus
    var newGames = 0
    var eligibleKnown = 0
    var windowCount = 0
    var monthsVisited = 0
    /// True when the intended scope was fully downloaded and the window may be published (§4).
    var boundedScopeComplete = false
    var error: ProviderError?
}

/// Stored month validators, so an unchanged archive is never downloaded twice.
final class ArchiveRepository {
    private let database: SQLiteDatabase
    init(database: SQLiteDatabase) { self.database = database }

    struct Record {
        var etag: String?
        var lastModified: String?
        var fetchedAt: Date?
        var complete: Bool
    }

    func record(playerID: UUID, year: Int, month: Int) throws -> Record? {
        guard let row = try database.queryOne("""
            SELECT etag, last_modified, fetched_at, complete FROM archives
            WHERE player_id = ? AND year = ? AND month = ?;
            """, [playerID.sqlValue, year.sqlValue, month.sqlValue]) else { return nil }
        return Record(etag: row.string("etag"),
                      lastModified: row.string("last_modified"),
                      fetchedAt: row.date("fetched_at"),
                      complete: row.bool("complete"))
    }

    func save(playerID: UUID, month: ProviderArchiveMonth, etag: String?, lastModified: String?, complete: Bool) throws {
        try database.run("""
            INSERT INTO archives (player_id, year, month, url, etag, last_modified, fetched_at, complete)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(player_id, year, month) DO UPDATE SET
                url = excluded.url, etag = excluded.etag, last_modified = excluded.last_modified,
                fetched_at = excluded.fetched_at, complete = excluded.complete;
            """, [playerID.sqlValue, month.year.sqlValue, month.month.sqlValue, month.url.sqlValue,
                  etag.sqlValue, lastModified.sqlValue, Date().sqlValue, complete.sqlValue])
    }

    func deleteAll(playerID: UUID) throws {
        try database.run("DELETE FROM archives WHERE player_id = ?;", [playerID.sqlValue])
    }
}

/// Downloads a player's public history and keeps the local copy in step with the provider.
///
/// The contract in §4 drives the shape: cached data is shown first, months are fetched newest
/// first, conditional requests avoid re-downloading unchanged archives, and free-window
/// membership is only published after a bounded refresh actually finishes.
final class ArchiveSyncService {
    static let freeWindowLimit = 1_000

    private let client: ChessComClient
    private let players: PlayerRepository
    private let games: GameRepository
    private let archives: ArchiveRepository

    init(client: ChessComClient, players: PlayerRepository, games: GameRepository, archives: ArchiveRepository) {
        self.client = client
        self.players = players
        self.games = games
        self.archives = archives
    }

    // MARK: - Identity

    func resolveProfile(username: String) async throws -> ProviderProfile {
        guard let normalized = ChessComClient.normalize(username: username) else {
            throw ProviderError.playerNotFound
        }
        return try await client.profile(username: normalized)
    }

    // MARK: - Refresh

    func refresh(player: TrackedPlayer,
                 scope: PlanScope,
                 progress: @escaping (RefreshProgress) -> Void) async -> RefreshOutcome {
        var outcome = RefreshOutcome(status: .upToDate)
        var state = RefreshProgress()

        let username = player.username
        do {
            // A profile fetch first: it detects a rename and confirms the identity still resolves.
            let profile = try await client.profile(username: username)
            if let providerID = profile.providerID, let existing = player.providerID, providerID != existing {
                // A different provider ID is a different player and must never merge (§4).
                outcome.status = .usernameUnavailable
                outcome.error = .playerNotFound
                return outcome
            }

            let months = try await client.archives(username: username)
            state.monthsTotal = months.count
            progress(state)

            var eligibleSeen = 0
            var stored = 0
            let now = Date()

            for month in months {
                state.currentMonthLabel = String(format: "%04d-%02d", month.year, month.month)
                progress(state)

                let cached = try archives.record(playerID: player.id, year: month.year, month: month.month)
                // A month keeps gaining games until it has ended, so it is revalidated on every
                // refresh until a fetch made after it settled. The stored flag alone is not
                // trusted: earlier builds marked every fetched month complete, which froze the
                // previous month at whatever it held before its last days were played. A settled
                // month is still re-checked occasionally as a safety net; conditional headers
                // make that a 304 when nothing changed.
                let settled = cached.map {
                    $0.complete && Self.isSettled(year: month.year, month: month.month, fetchedAt: $0.fetchedAt)
                } ?? false
                let validatorAge = cached?.fetchedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                let needsFetch = !settled || validatorAge > 30 * 86_400

                if needsFetch {
                    let response = try await client.games(month: month,
                                                          etag: cached?.etag,
                                                          lastModified: cached?.lastModified)
                    if !response.notModified {
                        let records = Self.records(from: response.games)
                        try games.upsert(records.map(\.record))
                        for entry in records {
                            try games.link(playerID: player.id, game: entry.record, color: entry.color(for: username))
                        }
                        stored += records.count
                        state.gamesStored = stored
                    }
                    try archives.save(playerID: player.id, month: month,
                                      etag: response.etag, lastModified: response.lastModified,
                                      complete: Self.isSettled(year: month.year, month: month.month, fetchedAt: Date()))
                }

                eligibleSeen = try games.totalGameCount(playerID: player.id)
                state.eligibleKnown = eligibleSeen
                state.monthsCompleted += 1
                progress(state)

                outcome.monthsVisited += 1
                // Free import stops once the complete latest-1,000 window is known (§4).
                if scope == .freeWindow, eligibleSeen >= Self.freeWindowLimit { break }
                if Task.isCancelled { throw ProviderError.cancelled }
            }

            outcome.newGames = stored
            outcome.eligibleKnown = eligibleSeen
            outcome.boundedScopeComplete = true
            outcome.windowCount = try games.publishFreeWindow(playerID: player.id, limit: Self.freeWindowLimit)
            outcome.status = .upToDate
        } catch let error as ProviderError {
            outcome.error = error
            switch error {
            case .playerNotFound: outcome.status = .usernameUnavailable
            case .offline: outcome.status = .offline
            case .rateLimited: outcome.status = .rateLimited
            case .cancelled: outcome.status = player.status
            default: outcome.status = .failed
            }
        } catch {
            outcome.error = .malformedResponse
            outcome.status = .failed
        }

        state.isFinished = true
        progress(state)
        return outcome
    }

    // MARK: - Archive months

    /// How long after a month ends its archive is still treated as changing. Covers games that
    /// finish in the last minutes of the month and the provider's own archive caching.
    static let archiveSettleDelay: TimeInterval = 86_400

    /// True when a fetch at `fetchedAt` saw the month's final contents.
    ///
    /// The provider files games by UTC month, so the boundary is computed in UTC — never in the
    /// device's time zone, where the new month can begin hours before or after the provider's.
    static func isSettled(year: Int, month: Int, fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let start = utc.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = utc.date(byAdding: .month, value: 1, to: start) else { return false }
        return fetchedAt >= end.addingTimeInterval(archiveSettleDelay)
    }

    // MARK: - Mapping

    struct MappedGame {
        var record: GameRecord
        var whiteUsername: String
        var blackUsername: String

        func color(for username: String) -> PieceColor {
            whiteUsername.lowercased() == username.lowercased() ? .white : .black
        }
    }

    /// Only standard chess in the four supported classes becomes a stored game. Unsupported
    /// games never enter the database, so they can never consume a free-window slot (§3).
    static func records(from providerGames: [ProviderGame]) -> [MappedGame] {
        providerGames.compactMap { game in
            guard game.rules == "chess", let timeClass = TimeClass(rawValue: game.timeClass) else { return nil }
            let parsed = PGNParser.parse(game.pgn)
            let key = GameIdentity.canonicalKey(uuid: game.uuid, url: game.url)
            let record = GameRecord(gameKey: key,
                                    url: game.url,
                                    uuid: game.uuid,
                                    pgn: game.pgn,
                                    startFEN: parsed.startFEN,
                                    moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                                    endTime: game.endTime,
                                    timeClass: timeClass,
                                    timeControl: game.timeControl,
                                    rules: game.rules,
                                    rated: game.rated,
                                    white: GameSide(username: game.whiteUsername,
                                                    rating: game.whiteRating,
                                                    resultCode: game.whiteResult),
                                    black: GameSide(username: game.blackUsername,
                                                    rating: game.blackRating,
                                                    resultCode: game.blackResult),
                                    eco: parsed.tags["ECO"],
                                    ecoURL: parsed.tags["ECOUrl"] ?? game.ecoURL,
                                    openingName: openingName(tags: parsed.tags, ecoURL: game.ecoURL),
                                    parseState: parsed.isValid ? .parsed : .malformed,
                                    plyCount: parsed.moves.count)
            return MappedGame(record: record, whiteUsername: game.whiteUsername, blackUsername: game.blackUsername)
        }
    }

    /// Opening metadata only: the `Opening` tag, then the provider's opening URL, then the bare
    /// ECO code. Nothing is inferred from a game URL, and absent metadata stays Unknown (§6).
    static func openingName(tags: [String: String], ecoURL: String?) -> String? {
        if let opening = tags["Opening"], !opening.isEmpty { return opening }
        if let url = tags["ECOUrl"] ?? ecoURL,
           let slug = URL(string: url)?.lastPathComponent, !slug.isEmpty, slug != "/" {
            if let name = openingName(fromSlug: slug) { return name }
        }
        if let eco = tags["ECO"], !eco.isEmpty { return eco }
        return nil
    }

    /// The provider's opening slugs append the defining move sequence to the name, as in
    /// `Sicilian-Defense-Katalimov-Variation...4.Nxd4-Bb7` or `Birds-Opening-Froms-Gambit-2.fxe5-d6`.
    /// Only the named part is the group: keeping the moves would split one opening into dozens of
    /// single-game rows and make the list useless.
    static func openingName(fromSlug slug: String) -> String? {
        var text = slug
        if let ellipsis = text.range(of: "...") { text = String(text[text.startIndex..<ellipsis.lowerBound]) }
        var words: [String] = []
        for component in text.split(separator: "-") {
            // Move text always starts with its move number, so the first digit ends the name.
            if component.first?.isNumber == true { break }
            words.append(String(component))
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(70))
    }
}
