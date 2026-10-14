//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
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
    /// Lichess has no months to count, so its progress is games stored out of the games the
    /// profile says there are, when it says.
    var gamesExpected = 0
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
        try database.run("DELETE FROM history_cursors WHERE player_id = ?;", [playerID.sqlValue])
    }

    /// How much of a Lichess history is stored, as game start times in milliseconds: everything
    /// from `oldest` to `newest` is downloaded, and nothing before `oldest` remains once
    /// `complete` is set.
    struct HistoryCursor: Equatable {
        var newest: Int?
        var oldest: Int?
        var complete = false
    }

    func cursor(playerID: UUID) throws -> HistoryCursor {
        guard let row = try database.queryOne("""
            SELECT newest_ms, oldest_ms, history_complete FROM history_cursors WHERE player_id = ?;
            """, [playerID.sqlValue]) else { return HistoryCursor() }
        return HistoryCursor(newest: row.int("newest_ms"), oldest: row.int("oldest_ms"),
                             complete: row.bool("history_complete"))
    }

    func save(_ cursor: HistoryCursor, playerID: UUID) throws {
        try database.run("""
            INSERT INTO history_cursors (player_id, newest_ms, oldest_ms, history_complete)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(player_id) DO UPDATE SET
                newest_ms = excluded.newest_ms, oldest_ms = excluded.oldest_ms,
                history_complete = excluded.history_complete;
            """, [playerID.sqlValue, cursor.newest.sqlValue, cursor.oldest.sqlValue, cursor.complete.sqlValue])
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
    private let lichess: LichessClient
    private let players: PlayerRepository
    private let games: GameRepository
    private let archives: ArchiveRepository

    init(client: ChessComClient, lichess: LichessClient, players: PlayerRepository, games: GameRepository,
         archives: ArchiveRepository) {
        self.client = client
        self.lichess = lichess
        self.players = players
        self.games = games
        self.archives = archives
    }

    // MARK: - Identity

    func resolveProfile(username: String, provider: Provider) async throws -> ProviderProfile {
        guard let normalized = provider.normalize(username: username) else {
            throw ProviderError.playerNotFound
        }
        switch provider {
        case .chessCom: return try await client.profile(username: normalized)
        case .lichess: return try await lichess.profile(username: normalized)
        }
    }

    // MARK: - Refresh

    func refresh(player: TrackedPlayer,
                 scope: PlanScope,
                 progress: @escaping (RefreshProgress) -> Void) async -> RefreshOutcome {
        switch player.provider {
        case .chessCom: return await refreshChessCom(player: player, scope: scope, progress: progress)
        case .lichess: return await refreshLichess(player: player, scope: scope, progress: progress)
        }
    }

    private func refreshChessCom(player: TrackedPlayer,
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
        } catch {
            record(error, player: player, in: &outcome)
        }

        state.isFinished = true
        progress(state)
        return outcome
    }

    /// A failed refresh keeps whatever it stored and says why it stopped.
    private func record(_ error: Error, player: TrackedPlayer, in outcome: inout RefreshOutcome) {
        guard let error = error as? ProviderError else {
            outcome.error = .malformedResponse
            outcome.status = .failed
            return
        }
        outcome.error = error
        switch error {
        case .playerNotFound: outcome.status = .usernameUnavailable
        case .offline: outcome.status = .offline
        case .rateLimited: outcome.status = .rateLimited
        case .cancelled: outcome.status = player.status
        default: outcome.status = .failed
        }
    }

    // MARK: - Lichess

    /// How far back each check for new games reaches past the newest game already stored.
    /// Lichess files games by when they started, so a game that started before the newest
    /// stored one but finished after the last check is only found by looking back a little.
    static let lichessOverlap = 86_400_000
    /// Correspondence games can run for weeks, so they get a longer look back of their own.
    static let lichessCorrespondenceOverlap = 90 * 86_400_000
    /// Games written to the database at a time while a stream is read.
    static let lichessBatchSize = 50

    /// Lichess has no monthly archives: the history is one stream, newest game first. Two passes
    /// keep the local copy complete even when a download is interrupted part-way:
    ///
    /// 1. New games: everything started since the newest stored game. The newest cursor only
    ///    moves once this pass has read to the end, so an interrupted pass is simply repeated.
    /// 2. History: older games, read backwards from the oldest stored game, with that cursor
    ///    saved after every batch. It stops once the whole history is stored, or, on the free
    ///    plan, once the latest 1,000 supported games are (§4).
    private func refreshLichess(player: TrackedPlayer,
                                scope: PlanScope,
                                progress: @escaping (RefreshProgress) -> Void) async -> RefreshOutcome {
        var outcome = RefreshOutcome(status: .upToDate)
        var state = RefreshProgress()
        let username = player.username

        do {
            let profile = try await lichess.profile(username: username)
            if let providerID = profile.providerID, let existing = player.providerID, providerID != existing {
                outcome.status = .usernameUnavailable
                outcome.error = .playerNotFound
                return outcome
            }
            if let total = profile.gameCount {
                state.gamesExpected = scope == .freeWindow ? min(total, Self.freeWindowLimit) : total
            }
            progress(state)

            var cursor = try archives.cursor(playerID: player.id)
            var stored = 0
            let store: ([ProviderGame]) throws -> Void = { [games] batch in
                let records = Self.records(from: batch)
                try games.upsert(records.map(\.record))
                for entry in records {
                    try games.link(playerID: player.id, game: entry.record, color: entry.color(for: username))
                }
                stored += records.count
                state.gamesStored = stored
                progress(state)
            }

            // 1. New games since the last check. A complete history with no newest game is an
            //    account that had none yet, so everything it has now is new.
            if cursor.newest != nil || cursor.complete {
                var latest = cursor.newest
                try await exportLichess(username: username,
                                        request: LichessExportRequest(since: cursor.newest.map { $0 - Self.lichessOverlap }),
                                        store: store) { latest = max(latest ?? $0, $0) }
                if profile.playsCorrespondence, let newest = cursor.newest {
                    try await exportLichess(username: username,
                                            request: LichessExportRequest(since: newest - Self.lichessCorrespondenceOverlap,
                                                                          perfTypes: ["correspondence"]),
                                            store: store) { _ in }
                }
                cursor.newest = latest
                try archives.save(cursor, playerID: player.id)
            }

            // 2. Older history, until it is complete or the free window is full.
            while !cursor.complete {
                let known = try games.totalGameCount(playerID: player.id)
                if scope == .freeWindow, known >= Self.freeWindowLimit { break }
                // Ask for what the free window still lacks, and never in tiny pieces: a few
                // games in each request are unsupported and dropped.
                let limit = scope == .freeWindow ? max(100, Self.freeWindowLimit - known) : nil
                var read = 0
                var buffer: [ProviderGame] = []
                // `until` is the oldest stored start: re-reading that one game is harmless, and
                // games that share its millisecond are not skipped.
                try await lichess.export(username: username,
                                         request: LichessExportRequest(until: cursor.oldest, max: limit)) { exported in
                    read += 1
                    if cursor.newest == nil { cursor.newest = exported.createdAt }
                    if let game = exported.game { buffer.append(game) }
                    cursor.oldest = min(cursor.oldest ?? exported.createdAt, exported.createdAt)
                    if buffer.count >= Self.lichessBatchSize {
                        try store(buffer)
                        buffer.removeAll()
                        try self.archives.save(cursor, playerID: player.id)
                    }
                }
                try store(buffer)
                // Fewer games than asked for, or no limit at all, means the stream reached the
                // first game on the account. A window that only re-read its boundary game did too.
                if limit == nil || read < (limit ?? 0) || read <= 1 { cursor.complete = true }
                try archives.save(cursor, playerID: player.id)
                outcome.monthsVisited += 1
                if Task.isCancelled { throw ProviderError.cancelled }
            }

            outcome.newGames = stored
            outcome.eligibleKnown = try games.totalGameCount(playerID: player.id)
            outcome.boundedScopeComplete = true
            outcome.windowCount = try games.publishFreeWindow(playerID: player.id, limit: Self.freeWindowLimit)
            outcome.status = .upToDate
            state.eligibleKnown = outcome.eligibleKnown
        } catch {
            record(error, player: player, in: &outcome)
        }

        state.isFinished = true
        progress(state)
        return outcome
    }

    /// Reads one window of the export into the database in batches, reporting each game's start.
    private func exportLichess(username: String, request: LichessExportRequest,
                               store: ([ProviderGame]) throws -> Void,
                               seen: (Int) -> Void) async throws {
        var buffer: [ProviderGame] = []
        try await lichess.export(username: username, request: request) { exported in
            seen(exported.createdAt)
            if let game = exported.game { buffer.append(game) }
            if buffer.count >= Self.lichessBatchSize {
                try store(buffer)
                buffer.removeAll()
            }
        }
        try store(buffer)
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
