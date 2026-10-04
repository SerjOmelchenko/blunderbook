//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation
import SwiftUI

/// Root application state and the only place services are wired together.
///
/// Boot order matters: the database opens and migrates first, then cached content is published
/// immediately, and only then does anything reach for the network or StoreKit. A launch with no
/// connectivity shows the last known history rather than an empty app (§4).
@MainActor
@Observable
final class AppModel {
    // Services
    let database: SQLiteDatabase
    let players: PlayerRepository
    let games: GameRepository
    let analyses: AnalysisRepository
    let statistics: StatisticsRepository
    let queue: QueueRepository
    let telemetry: AnalysisTelemetry
    let preferences: PreferencesRepository
    let archives: ArchiveRepository
    let sync: ArchiveSyncService
    let backup: BackupService
    let entitlement: EntitlementService
    let conditions: DeviceConditionsMonitor
    let coordinator: AnalysisCoordinator
    private let engine: ChessEngine?

    // State
    var trackedPlayers: [TrackedPlayer] = []
    var selectedPlayerID: UUID?
    var filters: GameFilters = .default
    var selectedTab: RootTab = .analytics
    var isRefreshing = false
    var refreshProgress: RefreshProgress?
    var refreshError: ProviderError?
    var bootError: String?
    /// Set when Stockfish could not be loaded. Analysis is unavailable while this is non-nil;
    /// there is no second engine to fall back to, and saved reviews stay readable regardless.
    var engineError: String?

    /// True when the app was launched with development fixtures, which keeps that database off
    /// the network. Always false in a release build.
    var isUsingFixtures: Bool {
        #if DEBUG
        return DevelopmentSeed.isRequested
        #else
        return false
        #endif
    }
    /// Bumped whenever stored data changes, so screens can reload without a global observer.
    private(set) var dataVersion = 0

    var selectedPlayer: TrackedPlayer? {
        guard let selectedPlayerID else { return trackedPlayers.first }
        return trackedPlayers.first { $0.id == selectedPlayerID } ?? trackedPlayers.first
    }

    var scope: PlanScope { entitlement.state.scope }
    var isPremium: Bool { entitlement.state.isPremium }

    // MARK: - Boot

    init() {
        let directory = AppModel.databaseDirectory()
        let path = directory.appendingPathComponent("chessanalyser.sqlite").path
        var openError: String?
        var database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(path: path)
            try Schema.migrate(database)
        } catch {
            // A database that cannot open is reported, not hidden; the app still launches so the
            // person can read the reason and reach Settings.
            openError = error.localizedDescription
            database = (try? SQLiteDatabase(path: ":memory:")) ?? (try! SQLiteDatabase(path: ":memory:"))
            try? Schema.migrate(database)
        }

        self.database = database
        bootError = openError
        players = PlayerRepository(database: database)
        games = GameRepository(database: database)
        analyses = AnalysisRepository(database: database)
        statistics = StatisticsRepository(database: database)
        queue = QueueRepository(database: database)
        telemetry = AnalysisTelemetry(directory: Self.databaseDirectory().appendingPathComponent("Telemetry", isDirectory: true))
        preferences = PreferencesRepository(database: database)
        archives = ArchiveRepository(database: database)
        sync = ArchiveSyncService(client: ChessComClient(), players: players, games: games, archives: archives)
        backup = BackupService(database: database, players: players, games: games, analyses: analyses)
        entitlement = EntitlementService(preferences: preferences)
        conditions = DeviceConditionsMonitor()
        coordinator = AnalysisCoordinator(queue: queue, games: games, analyses: analyses,
                                          preferences: preferences, conditions: conditions,
                                          telemetry: telemetry)
        // Stockfish is the only engine (§2). If its networks cannot be loaded, analysis is
        // unavailable and the app says so — it never silently substitutes a weaker engine whose
        // results would mix into the same policy's statistics.
        let stockfish = StockfishEngine()
        engine = stockfish
        if let stockfish {
            AnalysisPolicy.setActiveEngine(stockfish)
        } else {
            engineError = StockfishEngine.unavailableReason()
                ?? "Stockfish could not be loaded, so games cannot be analysed."
        }

        restorePreferences()
        reloadPlayers()
    }

    /// What the performance log needs to tell one phone and build from another.
    private static func launchDetails(engine: ChessEngine?) -> [String: Any] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        return ["model": model,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cores": ProcessInfo.processInfo.processorCount,
                "build": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
                "policy": AnalysisPolicy.identifier,
                "engine": engine.map { "\($0.engineIdentifier) \($0.searchConfigurationIdentifier)" } ?? "unavailable"]
    }

    static func databaseDirectory() -> URL {
        // Application Support, not Caches: user data must never be purgeable (§9).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("ChessAnalyser", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var hasStarted = false

    /// Starts services once. Called from the first scene and, for a background launch that never
    /// shows one, from the background-task handler.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        #if DEBUG
        if DevelopmentSeed.isRequested { DevelopmentSeed.seed(into: self) }
        #endif
        conditions.start()
        entitlement.start()
        telemetry.event("launch", Self.launchDetails(engine: engine))
        // Extra engines load on their own threads the first time each has a game; the networks
        // they load are shared, so each costs about 50 MB.
        if let engine { coordinator.start(engine: engine, makeEngine: { StockfishEngine() }) }
        Task {
            // Entitlement arrives asynchronously; the queue learns about it as soon as it does.
            while !Task.isCancelled {
                coordinator.updateEntitlement(isPremium: entitlement.state.isPremium)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if selectedPlayer != nil, UIApplication.shared.applicationState != .background {
            Task { await refreshSelectedPlayer() }
        }
    }

    // MARK: - Preferences

    private func restorePreferences() {
        if let text = preferences.string(PreferenceKey.selectedPlayer), let id = UUID(uuidString: text) {
            selectedPlayerID = id
        }
        if let stored: GameFilters = preferences.value(PreferenceKey.filters, as: GameFilters.self) {
            filters = stored
        }
        if let text = preferences.string(PreferenceKey.selectedTab), let tab = RootTab(rawValue: text) {
            selectedTab = tab
        }
    }

    func persistSelection() {
        preferences.set(PreferenceKey.selectedPlayer, selectedPlayerID?.uuidString)
        preferences.set(PreferenceKey.selectedTab, selectedTab.rawValue)
        preferences.setValue(PreferenceKey.filters, filters)
    }

    func updateFilters(_ newValue: GameFilters) {
        filters = newValue
        persistSelection()
        touch()
    }

    // MARK: - Players

    /// True while the free plan still has room for another tracked player.
    var canAddPlayer: Bool { isPremium || trackedPlayers.count < FreePlan.maxPlayers }

    func reloadPlayers() {
        trackedPlayers = (try? players.all()) ?? []
        if selectedPlayerID == nil { selectedPlayerID = trackedPlayers.first?.id }
        if let selectedPlayerID, !trackedPlayers.contains(where: { $0.id == selectedPlayerID }) {
            self.selectedPlayerID = trackedPlayers.first?.id
        }
        chooseSensibleTimeClass()
    }

    /// If the selected class has no games, fall back to the most-played live class, then Daily (§6).
    private func chooseSensibleTimeClass() {
        guard let player = selectedPlayer else { return }
        let counts = (try? database.query("""
            SELECT time_class AS name, COUNT(*) AS value FROM player_games
            WHERE player_id = ? GROUP BY time_class;
            """, [player.id.sqlValue])) ?? []
        var byClass: [TimeClass: Int] = [:]
        for row in counts {
            guard let name = row.string("name"), let timeClass = TimeClass(rawValue: name) else { continue }
            byClass[timeClass] = row.int("value") ?? 0
        }
        guard !byClass.isEmpty else { return }
        if (byClass[filters.timeClass] ?? 0) > 0 { return }
        let live = byClass.filter { $0.key.isLive }.max { $0.value < $1.value }
        filters.timeClass = live?.key ?? (byClass[.daily] != nil ? .daily : filters.timeClass)
    }

    func selectPlayer(_ player: TrackedPlayer) {
        selectedPlayerID = player.id
        persistSelection()
        chooseSensibleTimeClass()
        touch()
        Task { await refreshSelectedPlayer() }
    }

    func addPlayer(profile: ProviderProfile) throws -> TrackedPlayer {
        if let providerID = profile.providerID, let existing = try players.player(providerID: providerID) {
            // A duplicate identity switches to the existing profile rather than tracking twice (§8).
            selectPlayer(existing)
            return existing
        }
        if let existing = try players.player(username: profile.username) {
            selectPlayer(existing)
            return existing
        }
        guard canAddPlayer else { throw PlayerLimitError.freeLimitReached }
        var player = TrackedPlayer(providerID: profile.providerID,
                                   username: profile.username.lowercased(),
                                   displayUsername: profile.username)
        player.avatarURL = profile.avatarURL
        player.country = profile.country
        player.title = profile.title
        try players.save(player)
        reloadPlayers()
        selectedPlayerID = player.id
        persistSelection()
        return player
    }

    func removePlayer(_ player: TrackedPlayer) throws {
        try players.delete(id: player.id)
        try? archives.deleteAll(playerID: player.id)
        reloadPlayers()
        touch()
    }

    /// Relinks only when the new name resolves to the same provider ID (§4).
    enum RelinkResult { case relinked, mismatch(String), notFound }

    func relink(player: TrackedPlayer, to username: String) async -> RelinkResult {
        do {
            let profile = try await sync.resolveProfile(username: username)
            if let existing = player.providerID, let fetched = profile.providerID, existing != fetched {
                return .mismatch(profile.username)
            }
            if player.providerID == nil, profile.providerID == nil {
                return .mismatch(profile.username)
            }
            var updated = player
            updated.aliases.append(player.displayUsername)
            updated.username = profile.username.lowercased()
            updated.displayUsername = profile.username
            updated.providerID = profile.providerID ?? player.providerID
            updated.status = .upToDate
            try players.save(updated)
            reloadPlayers()
            return .relinked
        } catch {
            return .notFound
        }
    }

    // MARK: - Refresh

    /// The refresh in flight. Owned here rather than by whichever view asked for it.
    private var refreshTask: Task<Void, Never>?

    /// Downloads new games for the selected player; concurrent calls join the one in flight.
    ///
    /// Callers are views, and SwiftUI cancels `.task` and `.refreshable` work whenever a view
    /// disappears or is rebuilt — leaving the import screen, switching tabs, or the list swapping
    /// its empty state for rows as games arrive. The download therefore runs in a task the model
    /// owns and callers only wait for it: a caller's cancellation ends its wait, never the
    /// download, which would otherwise stop before the free window is published.
    func refreshSelectedPlayer() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor in
            await self.performRefresh()
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        guard !isUsingFixtures else { return }
        guard let player = selectedPlayer, !isRefreshing else { return }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        var updated = player
        updated.status = .downloading
        updated.lastChecked = Date()
        try? players.save(updated)
        reloadPlayers()

        let outcome = await sync.refresh(player: player, scope: scope) { [weak self] progress in
            Task { @MainActor in self?.refreshProgress = progress }
        }

        var result = player
        result.status = outcome.status
        result.lastChecked = Date()
        if outcome.error == nil {
            // A failed or partial refresh must not advance the successful timestamp (§4).
            result.lastSuccessfulRefresh = Date()
            result.hasVerifiedWindow = outcome.boundedScopeComplete
        }
        try? players.save(result)
        refreshError = outcome.error
        refreshProgress = nil
        reloadPlayers()
        touch()
    }

    // MARK: - Analysis actions

    /// True when the engine loaded and new analysis is possible.
    var canAnalyse: Bool { engine != nil }

    /// Why a review could not be started, for the caller to show.
    enum ReviewRefusal: Equatable {
        case engineUnavailable(String)
        case noPlayer
    }

    /// Queues a single review. Analysing a game you open is free on every plan.
    @discardableResult
    func requestReview(gameKey: String) -> ReviewRefusal? {
        guard let player = selectedPlayer else { return .noPlayer }
        if let engineError { return .engineUnavailable(engineError) }
        try? coordinator.requestReview(playerID: player.id, gameKey: gameKey)
        touch()
        return nil
    }

    /// Analysing a whole history in one go is the Premium feature.
    var canAnalyseInBulk: Bool { isPremium }

    /// Bulk covers the eligible games of the time class being viewed, known when the batch
    /// starts — not the whole profile.
    func eligibleBulkKeys() -> [String] {
        guard let player = selectedPlayer else { return [] }
        let all = (try? games.eligibleKeys(playerID: player.id, scope: scope, timeClass: filters.timeClass)) ?? []
        let done = Set(completedKeys(for: all))
        return all.filter { !done.contains($0) }
    }

    /// Keys that already have a current review. Queried in chunks, because SQLite caps the number
    /// of bound parameters; checking only the first chunk would re-queue every reviewed game
    /// beyond it.
    private func completedKeys(for keys: [String]) -> [String] {
        let chunkSize = 900
        var result: [String] = []
        for start in stride(from: 0, to: keys.count, by: chunkSize) {
            let slice = Array(keys[start..<min(start + chunkSize, keys.count)])
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            let rows = (try? database.query("""
                SELECT game_key AS value FROM analyses
                WHERE policy_id = ? AND status = 'complete' AND game_key IN (\(placeholders));
                """, [AnalysisPolicy.identifier.sqlValue] + slice.map { $0.sqlValue })) ?? []
            result += rows.compactMap { $0.string("value") }
        }
        return result
    }

    /// What a bulk run would cover right now: every game of the time class without a review.
    struct BulkPlan {
        var eligible: [String]
    }

    func bulkPlan() -> BulkPlan {
        BulkPlan(eligible: eligibleBulkKeys())
    }

    /// Queues every game in the plan. Premium only; returns how many games were queued.
    @discardableResult
    func startBulk() -> Int {
        guard canAnalyse, canAnalyseInBulk, let player = selectedPlayer else { return 0 }
        let keys = bulkPlan().eligible
        guard !keys.isEmpty else { return 0 }
        do {
            try coordinator.enqueueBulk(playerID: player.id,
                                        label: "\(player.displayUsername) · \(filters.timeClass.label)",
                                        gameKeys: keys)
            coordinator.resume()
        } catch {
            return 0
        }
        touch()
        return keys.count
    }

    // MARK: - Change notification

    func touch() { dataVersion &+= 1 }
}

enum RootTab: String, CaseIterable, Identifiable {
    case analytics, games, mistakes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .analytics: return "Analytics"
        case .games: return "Games"
        case .mistakes: return "Mistakes"
        }
    }

    var symbol: String {
        switch self {
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .games: return "list.bullet.rectangle"
        case .mistakes: return "exclamationmark.triangle"
        }
    }
}
