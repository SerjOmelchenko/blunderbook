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
    /// The moves of a review the person asked for that are scored so far, in order, for showing
    /// while the rest runs. Nothing is saved until the game is finished.
    case partial(gameKey: String, moves: [MoveAnalysis])
    case finished(gameKey: String, plies: Int)
    case failed(gameKey: String, message: String)
    /// Stopped before the end. The game goes back to the queue and is analysed again from the
    /// start: a game is analysed as one unit.
    case interrupted(gameKey: String)
    /// Nothing is pending for any engine.
    case idle
}

/// Which engine a worker drives, and so which work it may take.
enum EngineRole: Sendable, Hashable {
    /// The first performance-core engine: reviews the person asks for, which borrow every other
    /// engine, and bulk work while the device is cool.
    case performance
    /// Another performance-core engine, counted from 2: lent to reviews the person asks for, and
    /// nothing else, so bulk work never takes more than one performance core.
    case performanceHelper(Int)
    /// An efficiency-core engine, counted from 1: bulk work only.
    case efficiency(Int)

    var name: String {
        switch self {
        case .performance: return "P"
        case .performanceHelper(let index): return "P\(index)"
        case .efficiency(let index): return "E\(index)"
        }
    }
}

/// Every engine of the device, and which of them is busy. A worker runs its own games on its own
/// engine; a review the person asks for borrows all the others, so one game is split across the
/// whole device. Engines load on first use, one at a time: each load briefly holds a private copy
/// of the networks until it finds the shared one.
final class EnginePool: @unchecked Sendable {
    private let lock = NSLock()
    private let loadLock = NSLock()
    private let makeEngine: () -> ChessEngine?
    private var engines: [EngineRole: ChessEngine]
    private var unavailable: Set<EngineRole> = []
    private var busy: Set<EngineRole> = []

    init(performance: ChessEngine, makeEngine: @escaping () -> ChessEngine?) {
        engines = [.performance: performance]
        self.makeEngine = makeEngine
    }

    enum Taken {
        case engine(ChessEngine)
        /// Lent to a review the person asked for.
        case busy
        /// It could not load, and will not.
        case unavailable
    }

    func take(_ role: EngineRole) -> Taken {
        lock.lock()
        if unavailable.contains(role) { lock.unlock(); return .unavailable }
        if busy.contains(role) { lock.unlock(); return .busy }
        busy.insert(role)
        lock.unlock()
        if let engine = load(role) { return .engine(engine) }
        release([role])
        return .unavailable
    }

    func release(_ roles: [EngineRole]) {
        lock.lock()
        roles.forEach { busy.remove($0) }
        lock.unlock()
    }

    /// True while any of `roles` is analysing, apart from those that cannot load.
    func isAnyBusy(_ roles: [EngineRole]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return roles.contains { busy.contains($0) }
    }

    /// Takes every engine among `roles` that is free, loading any not loaded yet.
    func borrow(_ roles: [EngineRole]) -> [(role: EngineRole, engine: ChessEngine)] {
        roles.compactMap { role in
            if case .engine(let engine) = take(role) { return (role, engine) }
            return nil
        }
    }

    private func load(_ role: EngineRole) -> ChessEngine? {
        lock.lock()
        let loaded = engines[role]
        lock.unlock()
        if let loaded { return loaded }
        loadLock.lock()
        let engine = makeEngine()
        loadLock.unlock()
        lock.lock()
        if let engine { engines[role] = engine } else { unavailable.insert(role) }
        lock.unlock()
        return engine
    }
}

final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = true
    private var bulkAllowed = false
    private var currentPlan = ThermalPacing.Plan(performanceBulk: false, efficiencyEngines: 0)
    private var currentReviewDepth = ReviewDepth.default
    private var reviewing = false
    private var warm = false

    var isBlocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return blocked }
        set { lock.lock(); blocked = newValue; lock.unlock() }
    }

    /// Which engines may take bulk work right now (`ThermalPacing`).
    var plan: ThermalPacing.Plan {
        get { lock.lock(); defer { lock.unlock() }; return currentPlan }
        set { lock.lock(); currentPlan = newValue; lock.unlock() }
    }

    /// How deeply the next deep review searches. A game already running keeps the level it
    /// started with.
    var reviewDepth: ReviewDepth {
        get { lock.lock(); defer { lock.unlock() }; return currentReviewDepth }
        set { lock.lock(); currentReviewDepth = newValue; lock.unlock() }
    }

    /// False while the subscription does not cover bulk work.
    var allowsBulk: Bool {
        get { lock.lock(); defer { lock.unlock() }; return bulkAllowed }
        set { lock.lock(); bulkAllowed = newValue; lock.unlock() }
    }

    /// True while the device reports itself warm (`ProcessInfo.ThermalState.fair`). A review the
    /// person asked for then runs every engine at low priority, which keeps it on the cooler
    /// efficiency cores, so it carries on more slowly instead of heating up until everything stops.
    var isWarm: Bool {
        get { lock.lock(); defer { lock.unlock() }; return warm }
        set { lock.lock(); warm = newValue; lock.unlock() }
    }

    /// True while a review the person asked for has, or is gathering, every engine: no other
    /// worker takes a game meanwhile.
    var isReviewing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return reviewing }
        set { lock.lock(); reviewing = newValue; lock.unlock() }
    }
}

/// One engine and the loop that feeds it games, one game at a time. Several run side by side,
/// each on its own engine; a game never depends on which of them analysed it, because every
/// search starts from an engine that has forgotten everything (§5). The performance worker's
/// reviews for the person also borrow every other worker's engine.
final class AnalysisWorker: @unchecked Sendable {
    let role: EngineRole
    private let queue: QueueRepository
    private let games: GameRepository
    private let analyses: AnalysisRepository
    private let gate: WorkerGate
    private let pool: EnginePool
    private let cache: PositionCache?
    private let telemetry: AnalysisTelemetry.Channel?
    private let onEvent: @Sendable (AnalysisEvent) -> Void

    /// The other workers, whose engines a review for the person borrows. Set before `run()`.
    var others: [AnalysisWorker] = []

    /// How long a review waits for the other engines to stop their bulk games before it starts
    /// without the stragglers. A cancelled search stops within a fraction of a second.
    private static let gatherSeconds: TimeInterval = 2

    private let lock = NSLock()
    private var cancellation = CancellationToken()
    private var isRunningBulk = false

    init(role: EngineRole,
         queue: QueueRepository,
         games: GameRepository,
         analyses: AnalysisRepository,
         gate: WorkerGate,
         pool: EnginePool,
         cache: PositionCache?,
         telemetry: AnalysisTelemetry.Channel?,
         onEvent: @escaping @Sendable (AnalysisEvent) -> Void) {
        self.role = role
        self.queue = queue
        self.games = games
        self.analyses = analyses
        self.gate = gate
        self.pool = pool
        self.cache = cache
        self.telemetry = telemetry
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
            // Loaded on the worker's own thread the first time it has work, so loading the
            // networks never blocks the interface.
            switch pool.take(role) {
            case .engine(let engine):
                process(item, engine: engine)
                pool.release([role])
            case .busy:
                // Lent to a review that started after the claim: the game waits for it.
                try? queue.setState(.pending, id: item.id)
                try? await Task.sleep(nanoseconds: 250_000_000)
            case .unavailable:
                // This engine could not load. Its game goes back to the others, and it stops.
                try? queue.setState(.pending, id: item.id)
                telemetry?.event("engineUnavailable")
                return
            }
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
        case .performanceHelper:
            return nil
        case .efficiency(let index):
            guard gate.allowsBulk, index <= plan.efficiencyEngines, !gate.isReviewing else { return nil }
            return (try? queue.claimNextPendingItem(manual: false, bulk: true)) ?? nil
        }
    }

    /// Every other engine, once their bulk games have stopped: those go back to the queue.
    private func gatherEngines() -> [(role: EngineRole, engine: ChessEngine)] {
        gate.isReviewing = true
        others.forEach { $0.preemptBulk() }
        let roles = others.map(\.role)
        let deadline = Date().addingTimeInterval(Self.gatherSeconds)
        while pool.isAnyBusy(roles), Date() < deadline { usleep(20_000) }
        return pool.borrow(roles)
    }

    private func process(_ item: QueueItem, engine: ChessEngine) {
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

        // A review the person asked for is split across every engine; bulk games use one each.
        let isReview = !isBulk && role == .performance
        let borrowed = isReview ? gatherEngines() : []
        defer {
            pool.release(borrowed.map(\.role))
            if isReview { gate.isReviewing = false }
        }

        // Scheduling only: the results never depend on which core ran them.
        switch role {
        case .performance: engine.setWorkload(isBulk ? .bulk : .interactive)
        case .performanceHelper: engine.setWorkload(.interactive)
        case .efficiency: engine.setWorkload(.bulkCool)
        }
        // Efficiency-core engines stay below the person's own work even for their review, and every
        // engine does while the device is warm; checked every second, and a change applies from
        // each engine's next search. Each worker sets its own engine's workload again before its
        // next game.
        let pacing = isReview ? DispatchSource.makeTimerSource(queue: .global(qos: .utility)) : nil
        if let pacing {
            var wasWarm: Bool?
            let fastEngines = [engine] + borrowed.filter { if case .efficiency = $0.role { return false } else { return true } }.map(\.engine)
            let slowEngines = borrowed.filter { if case .efficiency = $0.role { return true } else { return false } }.map(\.engine)
            slowEngines.forEach { $0.setWorkload(.bulkCool) }
            pacing.schedule(deadline: .now(), repeating: 1)
            pacing.setEventHandler { [gate] in
                let warm = gate.isWarm
                guard warm != wasWarm else { return }
                wasWarm = warm
                fastEngines.forEach { $0.setWorkload(warm ? .bulkCool : .interactive) }
            }
            pacing.resume()
        }
        defer { pacing?.cancel() }
        onEvent(.started(gameKey: item.gameKey))
        telemetry?.gameStarted(plies: game.plyCount, bulk: isBulk)

        let fast = borrowed.filter { if case .efficiency = $0.role { return false } else { return true } }
        let slow = borrowed.filter { if case .efficiency = $0.role { return true } else { return false } }
        let analyzer = GameAnalyzer(engine: engine, helpers: fast.map(\.engine), slowHelpers: slow.map(\.engine),
                                    cache: cache, telemetry: telemetry)
        var lastProgress = Date.distantPast
        var lastPartial = Date.distantPast
        do {
            let result = try analyzer.analyze(game: game, deep: isDeep, reviewDepth: gate.reviewDepth,
                                              cancellation: token,
                                              onProgress: { [onEvent] completed, total in
                // For display only; a few updates a second are plenty.
                let now = Date()
                guard completed == total || now.timeIntervalSince(lastProgress) >= 0.25 else { return }
                lastProgress = now
                onEvent(.progress(gameKey: item.gameKey, completed: completed, total: total))
            }, onPartial: isReview ? { [onEvent] moves in
                // Only the game the person is looking at, a few times a second at most.
                let now = Date()
                guard moves.count == game.plyCount || now.timeIntervalSince(lastPartial) >= 0.25 else { return }
                lastPartial = now
                onEvent(.partial(gameKey: item.gameKey, moves: moves))
            } : nil)
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
    /// The scored moves of reviews the person asked for, while they run (`AnalysisEvent.partial`).
    private(set) var partialReviews: [String: [MoveAnalysis]] = [:]
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
    func start(engine: ChessEngine, makeEngine: @escaping () -> ChessEngine?, cache: PositionCache? = nil) {
        guard workerTasks.isEmpty else { return }
        try? queue.recoverInterruptedItems()
        try? queue.adoptCurrentPolicy()

        let pool = EnginePool(performance: engine, makeEngine: makeEngine)
        let roles = [EngineRole.performance]
            + (1..<ThermalPacing.performanceEngineCount).map { EngineRole.performanceHelper($0 + 1) }
            + (1...efficiencyLimit.maximum).map { EngineRole.efficiency($0) }
        for role in roles {
            let worker = AnalysisWorker(role: role, queue: queue, games: games, analyses: analyses,
                                        gate: gate, pool: pool, cache: cache,
                                        telemetry: telemetry?.channel(role.name)) { [weak self] event in
                // The main queue keeps each worker's events in order; tasks would not.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            }
            workers.append(worker)
        }
        for worker in workers {
            worker.others = workers.filter { $0 !== worker }
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

    /// Adds a single review ahead of any bulk work. The performance-core engine takes it and borrows
    /// every other engine; bulk games they were on go back to the queue.
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
        case .partial(let key, let moves):
            partialReviews[key] = moves
        case .finished(let key, let plies):
            activeGames[key] = nil
            partialReviews[key] = nil
            recordThroughput(plies: plies)
            Task { await refreshCounts() }
        case .failed(let key, let message):
            lastFailureMessage = message
            activeGames[key] = nil
            partialReviews[key] = nil
            Task { await refreshCounts() }
        case .interrupted(let key):
            activeGames[key] = nil
            partialReviews[key] = nil
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
        let plan = ThermalPacing.plan(thermal: conditions.thermalState, efficiencyEngines: efficiencyLimit.value,
                                      inBackground: UIApplication.shared.applicationState == .background)
        gate.plan = plan
        isPacing = !plan.performanceBulk || plan.efficiencyEngines < efficiencyLimit.maximum

        gate.isWarm = conditions.thermalState != .nominal
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
