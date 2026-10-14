//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
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
    let mistakeBook: MistakeBookRepository
    let queue: QueueRepository
    let telemetry: AnalysisTelemetry
    let preferences: PreferencesRepository
    let archives: ArchiveRepository
    let sync: ArchiveSyncService
    let backup: BackupService
    let entitlement: EntitlementService
    let conditions: DeviceConditionsMonitor
    let coordinator: AnalysisCoordinator
    /// The one-time tips on Games and the note on the first analysis.
    let tips: FirstRunTips
    private let engine: ChessEngine?

    // State
    var trackedPlayers: [TrackedPlayer] = []
    var selectedPlayerID: UUID?
    /// True while the welcome screen's add-player or backup flow is open. The welcome screen
    /// stays until it closes, so adding the first player does not swap the screen, and the sheet
    /// with it, out from under the import in progress.
    var isOnboarding = false
    var filters: GameFilters = .default
    var selectedTab: RootTab = .analytics
    /// The one game Mistakes is narrowed to, after its accuracy rings were tapped in Games. Not
    /// kept between launches.
    var mistakesGameKey: String?
    /// A kind of mistake to narrow Mistakes to as it opens, from a review's repeat count. Taken
    /// by the Mistakes screen and cleared.
    var mistakesKind: MistakeCategory?
    /// A screen to push on the current tab, from a view without a link of its own (a swipe
    /// action, a session button). Taken by the root view and cleared.
    var pendingRoute: Route?
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
    /// The Mistakes tab is Premium. Free, it shows a lock and opens a preview of itself instead.
    var isMistakesLocked: Bool {
        #if DEBUG
        if DevelopmentSeed.unlocksMistakes { return false }
        #endif
        return !entitlement.unlocksPremiumFeatures
    }

    // MARK: - Boot

    init() {
        // Read the opening book off the main thread, before the first game review needs it.
        Task.detached(priority: .utility) { _ = OpeningBook.shared }
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
        mistakeBook = MistakeBookRepository(database: database)
        queue = QueueRepository(database: database)
        telemetry = AnalysisTelemetry(directory: Self.databaseDirectory().appendingPathComponent("Telemetry", isDirectory: true))
        preferences = PreferencesRepository(database: database)
        tips = FirstRunTips(preferences: preferences)
        archives = ArchiveRepository(database: database)
        sync = ArchiveSyncService(client: ChessComClient(), lichess: LichessClient(), players: players, games: games,
                                  archives: archives)
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
        sharesUsageData = preferences.string(PreferenceKey.usageAnalyticsOff) != "1"
        UsageAnalytics.shared.configure(distinctID: sharesUsageData ? usageAnalyticsID() : nil,
                                        directory: Self.databaseDirectory())
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
        // The folder keeps the app's pre-Blunderbook name so existing installs keep their data.
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
        // Deep reviews tagged by older detectors are re-tagged from the lines they store, and
        // ones scored by an older scoring version are rescored from their stored losses;
        // nothing is searched again, so this takes moments even for hundreds of games.
        let database = self.database
        Task.detached(priority: .utility) {
            let repository = AnalysisRepository(database: database)
            let retagged = (try? repository.retagDeepReviews()) ?? 0
            let rescored = (try? repository.rescoreDeepReviews()) ?? 0
            if retagged + rescored > 0 { await MainActor.run { self.touch() } }
        }
        // Extra engines load on their own threads the first time each has a game; the networks
        // they load are shared, so each costs about 50 MB.
        if let engine {
            coordinator.start(engine: engine, makeEngine: { StockfishEngine() },
                              cache: PositionCache(repository: PositionCacheRepository(database: database)))
        }
        Task {
            // Entitlement arrives asynchronously; the queue learns about it as soon as it does.
            while !Task.isCancelled {
                coordinator.updateEntitlement(isPremium: entitlement.state.isPremium,
                                              unlocksDeeperReviews: entitlement.unlocksPremiumFeatures)
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

    // MARK: - Usage sharing

    /// Anonymous usage events go to PostHog while this is on, which it is unless turned off in
    /// About › Privacy.
    private(set) var sharesUsageData = true

    func setSharesUsageData(_ isOn: Bool) {
        sharesUsageData = isOn
        preferences.set(PreferenceKey.usageAnalyticsOff, isOn ? nil : "1")
        // Off forgets the ID, so sharing turned on again never continues the old history.
        if !isOn {
            preferences.set(PreferenceKey.usageAnalyticsID, nil)
            preferences.set(PreferenceKey.usageAnalyticsIDCreated, nil)
        }
        UsageAnalytics.shared.update(distinctID: isOn ? usageAnalyticsID() : nil)
    }

    /// How long one ID lasts. Privacy regulators allow an audience-measurement ID up to 13
    /// months without consent (CNIL); a year stays inside that.
    static let usageAnalyticsIDLifetime: TimeInterval = 365 * 24 * 60 * 60

    /// Replaces the ID once it is a year old. Checked at launch and each time the app comes to the
    /// front, so a phone that keeps the app running for weeks still gets its new ID on time.
    func renewUsageAnalyticsIDIfExpired() {
        guard sharesUsageData else { return }
        let current = preferences.string(PreferenceKey.usageAnalyticsID)
        let id = usageAnalyticsID()
        if id != current { UsageAnalytics.shared.update(distinctID: id) }
    }

    /// The random ID usage events are sent under, made the first time it is needed and again
    /// once it is a year old.
    private func usageAnalyticsID(now: Date = Date()) -> String {
        if let existing = preferences.string(PreferenceKey.usageAnalyticsID) {
            if let text = preferences.string(PreferenceKey.usageAnalyticsIDCreated), let created = Double(text) {
                if now.timeIntervalSince1970 - created < Self.usageAnalyticsIDLifetime { return existing }
            } else {
                // An ID from before IDs expired starts its year now.
                preferences.set(PreferenceKey.usageAnalyticsIDCreated, String(now.timeIntervalSince1970))
                return existing
            }
        }
        let id = UUID().uuidString.lowercased()
        preferences.set(PreferenceKey.usageAnalyticsID, id)
        preferences.set(PreferenceKey.usageAnalyticsIDCreated, String(now.timeIntervalSince1970))
        return id
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

    /// The time classes offered for the selected player's site.
    var timeClasses: [TimeClass] { (selectedPlayer?.provider ?? .chessCom).timeClasses }

    /// If the selected class has no games, fall back to the most-played live class, then Daily (§6).
    private func chooseSensibleTimeClass() {
        guard let player = selectedPlayer else { return }
        // Classical exists on Lichess only; a Chess.com player starts from Rapid instead.
        if !player.provider.timeClasses.contains(filters.timeClass) { filters.timeClass = .rapid }
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
        mistakesGameKey = nil
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
        if let existing = try players.player(username: profile.username, provider: profile.provider) {
            selectPlayer(existing)
            return existing
        }
        guard canAddPlayer else { throw PlayerLimitError.freeLimitReached }
        var player = TrackedPlayer(provider: profile.provider,
                                   providerID: profile.providerID,
                                   username: profile.username.lowercased(),
                                   displayUsername: profile.username)
        player.avatarURL = profile.avatarURL
        player.country = profile.country
        player.title = profile.title
        try players.save(player)
        UsageAnalytics.shared.track(.playerAdded(player.provider))
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
            let profile = try await sync.resolveProfile(username: username, provider: player.provider)
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
    /// Counts refreshes, so progress from an earlier one is never shown for a later one.
    private var refreshGeneration = 0

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

        // Progress arrives as separate main-actor tasks, so the last few can land after the
        // refresh has finished; those are dropped rather than left on screen.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let outcome = await sync.refresh(player: player, scope: scope) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isRefreshing, self.refreshGeneration == generation else { return }
                self.refreshProgress = progress
            }
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
        if let error = outcome.error { UsageAnalytics.shared.track(.refreshFailed(error)) }
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
        /// Another game is waiting or being analysed; only one is analysed at a time.
        case anotherGameAnalysing
    }

    /// True while any game waits for or is having its analysis. One game is analysed at a time,
    /// so nothing else can be started until it finishes.
    var isAnalysingAGame: Bool { coordinator.counts.pending + coordinator.counts.running > 0 }

    /// Queues a single review, or with `deep` a deep review. Analysing a game is free on every
    /// plan, deep or not. Refused while another game is analysed: one game at a time.
    @discardableResult
    func requestReview(gameKey: String, deep: Bool = false) -> ReviewRefusal? {
        let refusal = queueReview(gameKey: gameKey, deep: deep)
        UsageAnalytics.shared.track(refusal.map { .analysisRefused($0) }
                                    ?? .analysisRequested(depth: coordinator.effectiveReviewDepth))
        return refusal
    }

    private func queueReview(gameKey: String, deep: Bool) -> ReviewRefusal? {
        guard let player = selectedPlayer else { return .noPlayer }
        if let engineError { return .engineUnavailable(engineError) }
        // Read from the queue, not `coordinator.counts`, which catches up a moment later.
        let busy = ((try? queue.counts()).map { $0.pending + $0.running } ?? 0) > 0
        if busy, ((try? queue.activeItem(gameKey: gameKey)) ?? nil) == nil { return .anotherGameAnalysing }
        _ = try? coordinator.requestReview(playerID: player.id, gameKey: gameKey, deep: deep)
        touch()
        return nil
    }

    // MARK: - Opening a game when its analysis lands

    /// A game whose analysis was started in place: from its rings in Games or a row on
    /// Analytics. If the person is not touching
    /// the screen when the analysis lands, you fly through the rings into the game
    /// (`RevealPortal`): the row's rings if they are on screen, otherwise the bottom bar's.
    struct PendingReveal {
        var gameKey: String
    }

    /// The flight from a set of rings into the game, while it plays.
    struct Reveal: Equatable {
        var gameKey: String
        /// The rings' centre, in global coordinates.
        var origin: CGPoint
        /// The accuracies the rings settle on: this game, 30 days, 12 months.
        var values: [Double]
        /// When the rings stopped spinning, to pick them up at the same angles.
        var spunAt: Date
        /// From the bottom bar's rings rather than the row's: the bar stays up, rings hidden,
        /// until the screen is photographed.
        var fromBar: Bool
        /// The rings' size on screen against the row's 40 points: the bar shows them smaller.
        var ringScale: CGFloat
        /// The tab whose stack the game opens on: the one on screen.
        var tab: RootTab
        /// Set once the photo of the screen covers it: the bottom bar can go.
        var isCovered = false
        /// Set by the game's screen once it is on screen behind the photo of the list, so the
        /// flight never opens onto an empty screen.
        var hasArrived = false
    }

    @ObservationIgnored var pendingReveal: PendingReveal?
    /// When a finger last went down anywhere in the app (`TouchActivityMonitor`).
    @ObservationIgnored var lastTouchAt = Date.distantPast
    /// Kept by the root view: true while Games shows its list rather than a pushed screen.
    @ObservationIgnored var isGamesListShowing = true
    /// Kept by the root view: true while a game (or a puzzle or explore) is open on the tab on
    /// screen. The bottom bar hides over a game, so then there are no rings to fly through.
    @ObservationIgnored var isGameOnScreen = false
    /// Where the pending game's row rings are on screen, kept by the row while it is laid out.
    @ObservationIgnored var rowRingsFrame: (gameKey: String, frame: CGRect)?
    /// Where the bottom bar's rings are on screen, kept by the bar.
    @ObservationIgnored var barRingsFrame: CGRect?
    /// Where the bottom bar itself is on screen, kept by the bar: the first-analysis note opens
    /// out of it.
    @ObservationIgnored var barFrame: CGRect?
    var reveal: Reveal?

    /// How long the screen must have gone untouched for the game to open on its own: a person
    /// scrolling or tapping is never pulled away mid-gesture.
    static let revealIdle: TimeInterval = 2

    /// Starts a game's analysis in place (its rings in Games, a row on Analytics), to be opened
    /// when it lands.
    @discardableResult
    func analyseThenOpen(gameKey: String) -> ReviewRefusal? {
        let refusal = requestReview(gameKey: gameKey, deep: true)
        pendingReveal = refusal == nil ? PendingReveal(gameKey: gameKey) : nil
        return refusal
    }

    /// Called whenever the queue's counts change. Once the pending game's analysis has landed,
    /// opens it if nobody is touching the screen: from the row's rings when they are on screen
    /// in Games, otherwise from the bottom bar's. A failed analysis, a sheet, a game already
    /// open, the app in the background or VoiceOver (whose gestures never reach the app) all
    /// leave it where it is.
    func revealIfLanded() {
        guard let pending = pendingReveal, reveal == nil,
              ((try? queue.activeItem(gameKey: pending.gameKey)) ?? nil) == nil else { return }
        pendingReveal = nil
        guard let player = selectedPlayer,
              let entry = (try? games.entry(playerID: player.id, gameKey: pending.gameKey)) ?? nil,
              entry.hasDeepReview, let accuracy = entry.accuracy,
              Date().timeIntervalSince(lastTouchAt) >= Self.revealIdle,
              // A tip on screen counts as the person reading: the game stays where it is.
              tips.showing == nil,
              UIApplication.shared.applicationState == .active,
              !UIAccessibility.isVoiceOverRunning,
              !Self.isPresentingSheet else { return }
        let values = [accuracy, entry.accuracy30Days ?? 0, entry.accuracy12Months ?? 0]
        let screen = Self.keyWindow?.bounds ?? .zero
        if selectedTab == .games, isGamesListShowing,
           let row = rowRingsFrame, row.gameKey == pending.gameKey, screen.contains(row.frame) {
            reveal = Reveal(gameKey: pending.gameKey, origin: CGPoint(x: row.frame.midX, y: row.frame.midY),
                            values: values, spunAt: Date(), fromBar: false, ringScale: 1, tab: selectedTab)
        } else if !isGameOnScreen, let bar = barRingsFrame, screen.intersects(bar) {
            reveal = Reveal(gameKey: pending.gameKey, origin: CGPoint(x: bar.midX, y: bar.midY),
                            values: values, spunAt: Date(), fromBar: true,
                            ringScale: QueueAccessory.ringScale, tab: selectedTab)
        }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    static var isPresentingSheet: Bool { keyWindow?.rootViewController?.presentedViewController != nil }

    // MARK: - Premium

    /// Buys the monthly plan (with the free trial when the account can still have it), then
    /// tells the queue and every screen. Each place that sells Premium goes through here.
    func purchasePremium() async -> PurchaseOutcome {
        let outcome = await entitlement.purchase()
        UsageAnalytics.shared.track(.purchase(outcome))
        coordinator.updateEntitlement(isPremium: entitlement.state.isPremium)
        touch()
        return outcome
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
