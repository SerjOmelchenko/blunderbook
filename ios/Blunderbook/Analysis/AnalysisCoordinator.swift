//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation
import UIKit

/// Progress and lifecycle events published by the engines. Several games can be in progress at
/// once, one per engine, so every event names its game.
enum AnalysisEvent: Sendable {
    case started(gameKey: String)
    /// `completed` of `total` units of work: searched positions, then scored plies.
    case progress(gameKey: String, completed: Int, total: Int)
    case finished(gameKey: String, plies: Int)
    case failed(gameKey: String, message: String)
    /// Stopped before the end. The game goes back to the queue and is analysed again from the
    /// start: a game is analysed as one unit.
    case interrupted(gameKey: String)
    /// Nothing is pending for any engine.
    case idle
}

/// Which engine a worker drives, and so which work it may take.
enum EngineRole: Sendable, Equatable {
    /// The performance-core engine: reviews the person asks for, and bulk work while the phone is
    /// cool.
    case performance
    /// An efficiency-core engine, counted from 1: bulk work only.
    case efficiency(Int)

    var name: String {
        switch self {
        case .performance: return "P"
        case .efficiency(let index): return "E\(index)"
        }
    }
}

/// Lock-protected state the main actor uses to steer the engines without touching their
/// internals. Blockers compose on the coordinator side; workers only read the result.
final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = true
    private var bulkAllowed = false
    private var currentPlan = ThermalPacing.Plan(performanceBulk: false, efficiencyEngines: 0)
    private var currentReviewDepth = ReviewDepth.default

    var isBlocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return blocked }
        set { lock.lock(); blocked = newValue; lock.unlock() }
    }

    /// Which engines may take bulk work right now (`ThermalPacing`).
    var plan: ThermalPacing.Plan {
        get { lock.lock(); defer { lock.unlock() }; return currentPlan }
        set { lock.lock(); currentPlan = newValue; lock.unlock() }
    }

    /// How hard the next deep review confirms its candidate errors. A game already running keeps
    /// the level it started with.
    var reviewDepth: ReviewDepth {
        get { lock.lock(); defer { lock.unlock() }; return currentReviewDepth }
        set { lock.lock(); currentReviewDepth = newValue; lock.unlock() }
    }

    /// False while the subscription does not cover bulk work.
    var allowsBulk: Bool {
        get { lock.lock(); defer { lock.unlock() }; return bulkAllowed }
        set { lock.lock(); bulkAllowed = newValue; lock.unlock() }
    }
}

/// One engine and the loop that feeds it games, one game at a time. Several run side by side,
/// each on its own engine; a game never depends on which of them analysed it, because every game
/// starts from an engine that has forgotten everything (§5).
final class AnalysisWorker: @unchecked Sendable {
    let role: EngineRole
    private let queue: QueueRepository
    private let games: GameRepository
    private let analyses: AnalysisRepository
    private let gate: WorkerGate
    private let telemetry: AnalysisTelemetry.Channel?
    private let makeEngine: () -> ChessEngine?
    private let onEvent: @Sendable (AnalysisEvent) -> Void

    /// Created on the worker's own thread the first time it has work, so loading the networks
    /// never blocks the interface.
    private var engine: ChessEngine?
    private var analyzer: GameAnalyzer?

    private let lock = NSLock()
    private var cancellation = CancellationToken()
    private var isRunningBulk = false

    init(role: EngineRole,
         queue: QueueRepository,
         games: GameRepository,
         analyses: AnalysisRepository,
         gate: WorkerGate,
         telemetry: AnalysisTelemetry.Channel?,
         makeEngine: @escaping () -> ChessEngine?,
         onEvent: @escaping @Sendable (AnalysisEvent) -> Void) {
        self.role = role
        self.queue = queue
        self.games = games
        self.analyses = analyses
        self.gate = gate
        self.telemetry = telemetry
        self.makeEngine = makeEngine
        self.onEvent = onEvent
    }

    func run() async {
        while !Task.isCancelled {
            guard let item = claim() else {
                if role == .performance, !gate.isBlocked, ((try? queue.counts().pending) ?? 0) == 0 {
                    onEvent(.idle)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            guard let analyzer = loadAnalyzer() else {
                // This engine could not load. Its game goes back to the others, and it stops.
                try? queue.setState(.pending, id: item.id)
                telemetry?.event("engineUnavailable")
                return
            }
            process(item, analyzer: analyzer)
            await Task.yield()
        }
    }

    func cancelCurrent() {
        lock.lock()
        cancellation.cancel()
        lock.unlock()
    }

    /// Stops the current game if it is bulk work, so a review the person asked for can start.
    func preemptBulk() {
        lock.lock()
        if isRunningBulk { cancellation.cancel() }
        lock.unlock()
    }

    private func claim() -> QueueItem? {
        guard !gate.isBlocked else { return nil }
        let plan = gate.plan
        switch role {
        case .performance:
            return (try? queue.claimNextPendingItem(manual: true, bulk: gate.allowsBulk && plan.performanceBulk)) ?? nil
        case .efficiency(let index):
            guard gate.allowsBulk, index <= plan.efficiencyEngines else { return nil }
            return (try? queue.claimNextPendingItem(manual: false, bulk: true)) ?? nil
        }
    }

    private func loadAnalyzer() -> GameAnalyzer? {
        if let analyzer { return analyzer }
        guard let engine = makeEngine() else { return nil }
        let analyzer = GameAnalyzer(engine: engine, telemetry: telemetry)
        self.engine = engine
        self.analyzer = analyzer
        return analyzer
    }

    private func process(_ item: QueueItem, analyzer: GameAnalyzer) {
        guard let game = (try? games.game(key: item.gameKey)) ?? nil else {
            try? queue.setState(.failed, id: item.id, error: "The game is no longer stored")
            return
        }

        let isBulk = item.priority > QueueRepository.manualPriority
        let isDeep = DeepReview.isDeep(policyID: item.policyID)
        let token = CancellationToken()
        lock.lock()
        cancellation = token
        isRunningBulk = isBulk
        lock.unlock()
        // Blocked between the claim and here: the cancel that came meanwhile hit the old token.
        if gate.isBlocked { token.cancel() }

        // Scheduling only: the results never depend on which core ran them.
        switch role {
        case .performance: engine?.setWorkload(isBulk ? .bulk : .interactive)
        case .efficiency: engine?.setWorkload(.bulkCool)
        }
        onEvent(.started(gameKey: item.gameKey))
        telemetry?.gameStarted(plies: game.plyCount, bulk: isBulk)

        var lastProgress = Date.distantPast
        do {
            let result = try analyzer.analyze(game: game, deep: isDeep, reviewDepth: gate.reviewDepth,
                                              cancellation: token) { [onEvent] completed, total in
                // For display only; a few updates a second are plenty.
                let now = Date()
                guard completed == total || now.timeIntervalSince(lastProgress) >= 0.25 else { return }
                lastProgress = now
                onEvent(.progress(gameKey: item.gameKey, completed: completed, total: total))
            }
            try analyses.save(result)
            try queue.setState(.completed, id: item.id, checkpointPly: result.nextPly)
            telemetry?.gameEnded(outcome: "finished")
            // Only deep reviews are queued now, so they are what the estimate measures; a standard
            // analysis searches far less per move and would skew it.
            onEvent(.finished(gameKey: item.gameKey, plies: isDeep ? result.moves.count : 0))
        } catch AnalysisError.cancelled {
            try? queue.setState(.pending, id: item.id, checkpointPly: 0)
            telemetry?.gameEnded(outcome: "interrupted")
            onEvent(.interrupted(gameKey: item.gameKey))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // One failed game never stops the batch (§7).
            try? analyses.markFailed(gameKey: item.gameKey, message: message, policyID: item.policyID)
            try? queue.setState(.failed, id: item.id, error: message)
            telemetry?.gameEnded(outcome: "failed")
            onEvent(.failed(gameKey: item.gameKey, message: message))
        }

        lock.lock()
        isRunningBulk = false
        lock.unlock()
    }
}

/// Owns the queue's user-facing state: what is running, why it is not, and how long the rest
/// might take. Everything expensive happens on the engines; this type only steers and observes.
@MainActor
@Observable
final class AnalysisCoordinator {
    /// One game in progress on one engine.
    struct ActiveGame: Equatable {
        var label: String?
        var completed = 0
        var total = 0
        let startedAt: Date
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    private(set) var counts = QueueCounts()
    /// Games being analysed right now, one per busy engine.
    private(set) var activeGames: [String: ActiveGame] = [:]
    private(set) var lastFailureMessage: String?
    private(set) var blockers: Set<QueueBlocker> = []
    /// True while heat keeps bulk work below the phone's full set of engines.
    private(set) var isPacing = false
    private(set) var isEstimating = true
    /// Active processing time, not calendar time (§7).
    private(set) var estimatedRemaining: ClosedRange<TimeInterval>?
    /// How many efficiency-core engines bulk work may use, learned from how the phone copes.
    private(set) var efficiencyLimit = EfficiencyEngineLimit(maximum: ThermalPacing.efficiencyEngineCount)

    var isPausedByUser: Bool {
        didSet {
            preferences.set(PreferenceKey.queuePaused, isPausedByUser ? "1" : "0")
            recomputeBlockers()
        }
    }

    /// Chosen in Settings. Applies to deep reviews that start after the change.
    var reviewDepth: ReviewDepth {
        didSet {
            preferences.set(PreferenceKey.reviewDepth, reviewDepth.rawValue)
            gate.reviewDepth = effectiveReviewDepth
        }
    }

    /// The level reviews run at: the chosen one, or the deepest free one when it needs Premium.
    var effectiveReviewDepth: ReviewDepth { reviewDepth.available(isPremium: unlocksDeeperReviews) }

    private let queue: QueueRepository
    private let games: GameRepository
    private let analyses: AnalysisRepository
    private let preferences: PreferencesRepository
    private let conditions: DeviceConditionsMonitor
    private let telemetry: AnalysisTelemetry?
    private let gate = WorkerGate()
    private var workers: [AnalysisWorker] = []
    private var workerTasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var isPremium = false
    /// Like `isPremium`, but also true while a known subscription is still being confirmed, so a
    /// subscriber's first review after launch is not run shallower.
    private var unlocksDeeperReviews = false
    /// When the last game finished, for the throughput estimate.
    private var lastFinishAt: Date?
    /// Called when the person explicitly starts or resumes work. Background execution may only be
    /// requested in response to such an action (§7).
    var onUserStartedWork: (() -> Void)?
    /// Sees every worker event after the coordinator has applied it; used to report progress to
    /// the system while analysis continues in the background.
    var eventObserver: ((AnalysisEvent) -> Void)?
    /// True while the app is in the background without granted execution time. Not a
    /// `QueueBlocker`: nothing is waiting on the person, and it clears on its own.
    private var isSuspendedForBackground = false

    init(queue: QueueRepository,
         games: GameRepository,
         analyses: AnalysisRepository,
         preferences: PreferencesRepository,
         conditions: DeviceConditionsMonitor,
         telemetry: AnalysisTelemetry? = nil) {
        self.queue = queue
        self.games = games
        self.analyses = analyses
        self.preferences = preferences
        self.conditions = conditions
        self.telemetry = telemetry
        self.isPausedByUser = preferences.string(PreferenceKey.queuePaused) == "1"
        self.reviewDepth = preferences.string(PreferenceKey.reviewDepth).flatMap(ReviewDepth.init(rawValue:)) ?? .default
        gate.reviewDepth = effectiveReviewDepth
    }

    /// The game the queue shows: the one that started first, so its bar moves steadily.
    var focusGame: (key: String, game: ActiveGame)? {
        activeGames.min { $0.value.startedAt < $1.value.startedAt }.map { (key: $0.key, game: $0.value) }
    }

    var currentGameKey: String? { focusGame?.key }
    var currentGameLabel: String? { focusGame?.game.label }
    var currentFraction: Double { focusGame?.game.fraction ?? 0 }

    /// How far along a game is, or nil when no engine is analysing it.
    func fraction(forGame gameKey: String) -> Double? { activeGames[gameKey]?.fraction }

    /// - Parameters:
    ///   - engine: the performance-core engine, already loaded.
    ///   - makeEngine: loads one more engine; each efficiency-core worker calls it on its own
    ///     thread the first time it has work.
    func start(engine: ChessEngine, makeEngine: @escaping () -> ChessEngine?) {
        guard workerTasks.isEmpty else { return }
        try? queue.recoverInterruptedItems()
        try? queue.adoptCurrentPolicy()

        // One engine loads at a time. Each load holds a private copy of the networks until it
        // finds the shared one, so loading four at once would briefly need four copies.
        let loadLock = NSLock()
        let loadOneAtATime: () -> ChessEngine? = {
            loadLock.lock()
            defer { loadLock.unlock() }
            return makeEngine()
        }

        let roles = [EngineRole.performance] + (1...efficiencyLimit.maximum).map { EngineRole.efficiency($0) }
        for role in roles {
            let worker = AnalysisWorker(role: role, queue: queue, games: games, analyses: analyses,
                                        gate: gate, telemetry: telemetry?.channel(role.name),
                                        makeEngine: role == .performance ? { engine } : loadOneAtATime) { [weak self] event in
                // The main queue keeps each worker's events in order; tasks would not.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            }
            workers.append(worker)
            workerTasks.append(Task.detached(priority: .utility) { await worker.run() })
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCounts()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if telemetry != nil {
            telemetryTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.telemetryInterval * 1_000_000_000))
                    self?.sampleTelemetry()
                }
            }
        }
        recomputeBlockers()
    }

    /// Seconds between performance samples.
    static let telemetryInterval: TimeInterval = 15

    private func sampleTelemetry() {
        guard let telemetry else { return }
        let plan = gate.plan
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        telemetry.sample(AnalysisTelemetry.Conditions(
            thermal: conditions.thermalDescription,
            battery: conditions.batteryLevel,
            charging: conditions.isCharging,
            lowPower: conditions.isLowPowerMode,
            engines: (plan.performanceBulk ? "P+" : "") + "\(plan.efficiencyEngines)E",
            blockers: blockers.map(\.rawValue).sorted(),
            pausedByUser: isPausedByUser,
            suspendedForBackground: isSuspendedForBackground,
            appState: appState,
            activeGames: activeGames.count,
            pendingGames: counts.pending,
            pendingPlies: (try? queue.pendingPlyEstimate()) ?? 0))
    }

    func stop() {
        workerTasks.forEach { $0.cancel() }
        refreshTask?.cancel()
        telemetryTask?.cancel()
        telemetryTask = nil
        cancelAllGames()
        workerTasks = []
        workers = []
        refreshTask = nil
    }

    func updateEntitlement(isPremium: Bool, unlocksDeeperReviews: Bool? = nil) {
        self.isPremium = isPremium
        self.unlocksDeeperReviews = unlocksDeeperReviews ?? isPremium
        gate.reviewDepth = effectiveReviewDepth
        recomputeBlockers()
    }

    // MARK: - Commands

    func pause() {
        isPausedByUser = true
        cancelAllGames()
        telemetry?.event("paused")
    }

    /// Only an explicit resume clears a user pause; recovery, charging or renewal does not (§7).
    func resume() {
        isPausedByUser = false
        telemetry?.event("resumed")
        onUserStartedWork?()
    }

    /// Stops the engines while the app has no execution time, and lets them run again once it
    /// has. A user pause or device blocker still applies on top.
    func setSuspendedForBackground(_ suspended: Bool) {
        guard isSuspendedForBackground != suspended else { return }
        isSuspendedForBackground = suspended
        telemetry?.event(suspended ? "suspendedForBackground" : "backgroundTimeGranted")
        recomputeBlockers()
    }

    /// True when something is queued that an engine would pick up. Reads the store directly so
    /// the answer is never a refresh behind.
    var hasUnfinishedWork: Bool {
        let current = (try? queue.counts()) ?? counts
        return current.pending + current.running > 0
    }

    /// True while any engine is part way through a game.
    var isAnalysingGame: Bool { !activeGames.isEmpty }

    /// Removes everything not yet analysed. Finished reviews are kept.
    func cancelAll() throws {
        cancelAllGames()
        try queue.cancelAll()
        Task { await refreshCounts() }
    }

    func retryFailed() throws {
        try queue.retryFailed()
        Task { await refreshCounts() }
    }

    func clearFinished() throws {
        try queue.clearFinished()
        Task { await refreshCounts() }
    }

    /// Adds a single review ahead of any bulk work. It runs on the performance-core engine, which
    /// drops any bulk game it is on; that game goes back to the queue.
    ///
    /// A user pause is deliberately *not* lifted here: §7 says only an explicit Resume clears it.
    /// The item is queued at manual priority and the caller tells the person the queue is paused.
    @discardableResult
    func requestReview(playerID: UUID, gameKey: String, deep: Bool = false) throws -> UUID {
        let id = try queue.enqueueManual(playerID: playerID, gameKey: gameKey, bucket: .none,
                                         policyID: deep ? DeepReview.identifier : AnalysisPolicy.identifier)
        workers.first { $0.role == .performance }?.preemptBulk()
        Task { await refreshCounts() }
        if !isPausedByUser { onUserStartedWork?() }
        return id
    }

    /// A hundred-game batch gets the same in-depth review as a game opened on its own.
    func enqueueBulk(playerID: UUID, label: String, gameKeys: [String]) throws {
        try queue.createBatch(playerID: playerID, label: label,
                              entries: gameKeys.map { (gameKey: $0, bucket: AllowanceBucket.none) },
                              policyID: DeepReview.identifier)
        Task { await refreshCounts() }
        if !isPausedByUser { onUserStartedWork?() }
    }

    // MARK: - State

    private func cancelAllGames() {
        workers.forEach { $0.cancelCurrent() }
    }

    private func handle(_ event: AnalysisEvent) {
        switch event {
        case .started(let key):
            activeGames[key] = ActiveGame(label: label(for: key), startedAt: Date())
        case .progress(let key, let completed, let total):
            activeGames[key]?.completed = completed
            activeGames[key]?.total = total
        case .finished(let key, let plies):
            activeGames[key] = nil
            recordThroughput(plies: plies)
            Task { await refreshCounts() }
        case .failed(let key, let message):
            lastFailureMessage = message
            activeGames[key] = nil
            Task { await refreshCounts() }
        case .interrupted(let key):
            activeGames[key] = nil
        case .idle:
            break
        }
        eventObserver?(event)
    }

    /// Several games run at once, so the estimate comes from how often games finish across all
    /// engines, not from how long any one game took. A gap with the work stopped is no sample.
    private func recordThroughput(plies: Int) {
        let now = Date()
        defer { lastFinishAt = now }
        guard let last = lastFinishAt, plies > 0 else { return }
        let gap = now.timeIntervalSince(last)
        guard gap < 300 else { return }
        try? queue.recordTiming(plies: plies, seconds: gap)
    }

    private func label(for gameKey: String) -> String? {
        guard let game = (try? games.game(key: gameKey)) ?? nil else { return nil }
        return "\(game.white.username) vs \(game.black.username)"
    }

    func refreshCounts() async {
        counts = (try? queue.counts()) ?? QueueCounts()
        recomputeBlockers()
        updateEstimate()
    }

    /// The displayed reason is the highest-priority one; the rest stay discoverable (§7).
    var primaryBlocker: QueueBlocker? {
        blockers.min { $0.priority < $1.priority }
    }

    var otherBlockers: [QueueBlocker] {
        guard let primary = primaryBlocker else { return [] }
        return blockers.filter { $0 != primary }.sorted { $0.priority < $1.priority }
    }

    private func recomputeBlockers() {
        var result = conditions.blockers
        if isPausedByUser { result.insert(.user) }
        // Entitlement is not a queue blocker: Premium gates *starting* a bulk run, and work
        // already queued finishes even if the subscription lapses meanwhile.
        gate.allowsBulk = true
        blockers = result

        // Learn from heat before the thermal blocker stops the games that caused it.
        efficiencyLimit.update(thermal: conditions.thermalState, isWorking: !activeGames.isEmpty)
        let plan = ThermalPacing.plan(thermal: conditions.thermalState, efficiencyEngines: efficiencyLimit.value)
        gate.plan = plan
        isPacing = !plan.performanceBulk || plan.efficiencyEngines < efficiencyLimit.maximum

        let blocked = !result.isEmpty || isSuspendedForBackground
        gate.isBlocked = blocked
        if blocked {
            cancelAllGames()
            lastFinishAt = nil
        }
    }

    private func updateEstimate() {
        let median = (try? queue.medianSecondsPerPly()) ?? nil
        let samples = (try? queue.timingSampleCount()) ?? 0
        isEstimating = median == nil
        guard let median, samples >= 3 else {
            estimatedRemaining = nil
            return
        }
        let remainingPlies = (try? queue.pendingPlyEstimate()) ?? 0
        guard remainingPlies > 0 else {
            estimatedRemaining = nil
            return
        }
        let centre = median * Double(remainingPlies)
        estimatedRemaining = (centre * 0.7)...(centre * 1.4)
    }
}
