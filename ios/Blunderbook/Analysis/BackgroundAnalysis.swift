//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import BackgroundTasks
import Foundation
import UIKit
import os

/// Decides when the analysis queue may run while the app is not on screen (§7).
///
/// - **iOS 26+:** work the person starts or resumes is submitted as a `BGContinuedProcessingTask`,
///   which keeps running in the background with real progress in the system UI. If that task
///   expires while the app is in the background — the person cancelled it from the system
///   indicator, or the system took the time back — the queue is paused, and only Resume starts it
///   again. It is never rescheduled on its own.
/// - **Every version:** without such a task, the engines stop when the app leaves the screen and
///   their games go back to the queue, and an opportunistic `BGProcessingTask` (external power,
///   no network) is requested for whatever is left. That is the only background path on iOS 17–25.
///
/// No duration is promised, and nothing restarts after a force-quit. Finished games are saved as
/// they finish; a game stopped part way is analysed again from its start on a later run.
@MainActor
final class BackgroundAnalysisController {
    static let shared = BackgroundAnalysisController()

    private static let log = Logger(subsystem: "Blunderbook", category: "background")
    nonisolated private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.example.chessanalyser" }
    nonisolated static var processingIdentifier: String { bundleID + ".analysis.processing" }
    nonisolated static var continuedPrefix: String { bundleID + ".analysis.continued." }

    /// A blocked continued task gives its time back after this long rather than sitting idle.
    private let blockedGiveUpSeconds: TimeInterval = 20
    /// How long a backgrounding app stays alive for the engines to stop and hand their games back.
    private let stopGraceSeconds: TimeInterval = 8

    private weak var model: AppModel?
    private var coordinator: AnalysisCoordinator? { model?.coordinator }
    private var isRegistered = false
    private var isInBackground = false

    /// Held as `BGTask` so the stored property needs no availability annotation.
    private var continuedTask: BGTask?
    private var isSubmittingContinued = false
    private var processingTask: BGProcessingTask?
    private var session = SessionProgress()
    private var blockedSince: Date?
    private var watchdog: Timer?

    private var graceTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Setup

    /// Registers the launch handler for opportunistic work. Must run before launch finishes.
    func registerLaunchHandlers() {
        guard !isRegistered else { return }
        isRegistered = true
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingIdentifier,
                                                         using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                BackgroundAnalysisController.shared.run(processing: task)
            }
        }
        if !registered {
            Self.log.error("Processing task identifier is missing from BGTaskSchedulerPermittedIdentifiers")
        }
    }

    /// Connects the controller to the app. The coordinator reports user actions and progress here.
    func attach(model: AppModel) {
        self.model = model
        model.coordinator.onUserStartedWork = { [weak self] in self?.userStartedWork() }
        model.coordinator.eventObserver = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Scene phase

    func sceneDidEnterBackground() {
        isInBackground = true
        guard let coordinator else { return }
        // A running continued or processing task keeps the worker going.
        guard continuedTask == nil, processingTask == nil else { return }
        stopEngines(coordinator)
        scheduleProcessingIfUseful()
    }

    func sceneDidBecomeActive() {
        isInBackground = false
        endStopGrace()
        coordinator?.setSuspendedForBackground(false)
        // Foreground work needs no opportunistic request; a new one is made on the next exit.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
    }

    // MARK: - iOS 26 continued processing

    /// Asks for continued processing because the person just started or resumed work.
    private func userStartedWork() {
        guard #available(iOS 26.0, *) else { return }
        guard continuedTask == nil, !isSubmittingContinued,
              UIApplication.shared.applicationState == .active,
              let model, model.canAnalyse,
              !model.coordinator.isPausedByUser, model.coordinator.hasUnfinishedWork else { return }
        submitContinued()
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        // Continued-processing handlers may be registered at any time, but only once per
        // identifier, so every submission gets its own.
        let identifier = Self.continuedPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                                         using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                BackgroundAnalysisController.shared.run(continued: task)
            }
        }
        guard registered else {
            Self.log.error("Continued-processing identifier is not permitted")
            return
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: "Analysing games",
                                                       subtitle: "Starting Stockfish")
        // Work runs in the foreground anyway; if the system cannot take it now, the ordinary
        // path applies rather than a queued request the person did not see start.
        request.strategy = .fail
        isSubmittingContinued = true
        Task { @MainActor in
            defer { isSubmittingContinued = false }
            do {
                if #available(iOS 27.0, *) {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } else {
                    try BGTaskScheduler.shared.submit(request)
                }
            } catch {
                Self.log.notice("Continued processing not granted: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @available(iOS 26.0, *)
    private func run(continued task: BGContinuedProcessingTask) {
        guard let coordinator, !coordinator.isPausedByUser, coordinator.hasUnfinishedWork else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        session = SessionProgress(remaining: unfinishedCount())
        task.progress.totalUnitCount = session.totalUnits
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedTaskExpired() }
        }
        if isInBackground { coordinator.setSuspendedForBackground(false) }
        startWatchdog()
        publishProgress()
    }

    /// The system ended the task. In the background this is either the person cancelling from the
    /// system indicator or the system taking the time back; the two cannot be told apart, so it
    /// becomes a user pause rather than a silent reschedule (§7). In the foreground nothing needs
    /// to stop: the queue simply carries on on screen.
    private func continuedTaskExpired() {
        guard let task = continuedTask else { return }
        continuedTask = nil
        stopWatchdog()
        if isInBackground, let coordinator {
            coordinator.pause()
            beginStopGrace()
        }
        task.setTaskCompleted(success: false)
    }

    private func finishContinued(success: Bool) {
        guard let task = continuedTask else { return }
        continuedTask = nil
        stopWatchdog()
        if success, #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task.setTaskCompleted(success: success)
        if isInBackground, let coordinator {
            stopEngines(coordinator)
            scheduleProcessingIfUseful()
        }
    }

    // MARK: - Opportunistic processing (all versions)

    private func scheduleProcessingIfUseful() {
        guard let model, model.canAnalyse,
              !model.coordinator.isPausedByUser, model.coordinator.hasUnfinishedWork else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        // Bulk analysis is heavy; the opportunistic path only asks for time on external power,
        // and never needs the network once games are stored (§7).
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator and devices with Background App Refresh off land here. Work carries on
            // the next time the app is opened.
            Self.log.notice("Background processing not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func run(processing task: BGProcessingTask) {
        // A background launch never connects a scene, so the app model has to start here.
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        model.start()
        let coordinator = model.coordinator
        guard model.canAnalyse, !coordinator.isPausedByUser, coordinator.hasUnfinishedWork else {
            task.setTaskCompleted(success: true)
            return
        }
        processingTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.processingTaskExpired() }
        }
        coordinator.setSuspendedForBackground(false)
        startWatchdog()
    }

    /// The system wants its time back. Stop the engines and ask again later; this is not a user
    /// action, so the queue is not paused.
    private func processingTaskExpired() {
        guard let task = processingTask else { return }
        processingTask = nil
        stopWatchdog()
        if isInBackground, let coordinator {
            stopEngines(coordinator)
            scheduleProcessingIfUseful()
        }
        task.setTaskCompleted(success: false)
    }

    private func finishProcessing(success: Bool) {
        guard let task = processingTask else { return }
        processingTask = nil
        stopWatchdog()
        task.setTaskCompleted(success: success)
        if isInBackground, let coordinator {
            stopEngines(coordinator)
            if !success { scheduleProcessingIfUseful() }
        }
    }

    // MARK: - Worker events

    private func handle(_ event: AnalysisEvent) {
        switch event {
        case .started(let gameKey):
            session.beginGame(gameKey: gameKey)
        case .progress(let gameKey, let completed, let total):
            session.advance(gameKey: gameKey, completed: completed, total: total)
        case .partial:
            return
        case .finished(let gameKey, _), .failed(let gameKey, _):
            session.finishGame(gameKey: gameKey)
            session.remaining = max(0, unfinishedCount() - (coordinator?.activeGames.count ?? 0))
        case .interrupted(let gameKey):
            session.interruptGame(gameKey: gameKey)
            // Every engine has stopped: nothing left to wait for.
            if coordinator?.isAnalysingGame != true { endStopGrace() }
        case .idle:
            // Nothing left that the worker may take: the batch is done or was cancelled.
            if !(coordinator?.hasUnfinishedWork ?? false) {
                finishContinued(success: true)
                finishProcessing(success: true)
            }
        }
        publishProgress()
    }

    private func publishProgress() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        let total = session.totalUnits
        if task.progress.totalUnitCount != total { task.progress.totalUnitCount = total }
        task.progress.completedUnitCount = min(total, session.completedUnits)

        let subtitle = session.subtitle(label: coordinator?.currentGameLabel)
        if task.subtitle != subtitle {
            task.updateTitle("Analysing games", subtitle: subtitle)
        }
    }

    // MARK: - Blocked while holding a task

    /// A device blocker (heat, battery, storage…) or a pause stops the worker without an event.
    /// Holding background time while nothing runs helps no one, so the task is given back.
    private func startWatchdog() {
        stopWatchdog()
        blockedSince = nil
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in BackgroundAnalysisController.shared.checkBlocked() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        blockedSince = nil
    }

    private func checkBlocked() {
        guard let coordinator else { return }
        if coordinator.isPausedByUser {
            finishContinued(success: false)
            finishProcessing(success: false)
            return
        }
        guard !coordinator.blockers.isEmpty else { blockedSince = nil; return }
        let since = blockedSince ?? Date()
        blockedSince = since
        if Date().timeIntervalSince(since) >= blockedGiveUpSeconds {
            finishContinued(success: false)
            finishProcessing(success: false)
        }
    }

    // MARK: - Stopping on exit

    /// Stops the engines, keeping the app alive just long enough for their games to go back to
    /// the queue.
    private func stopEngines(_ coordinator: AnalysisCoordinator) {
        let wasRunning = coordinator.isAnalysingGame
        coordinator.setSuspendedForBackground(true)
        if wasRunning { beginStopGrace() }
    }

    private func beginStopGrace() {
        guard graceTaskID == .invalid else { return }
        graceTaskID = UIApplication.shared.beginBackgroundTask(withName: "Stopping analysis") { [weak self] in
            Task { @MainActor in self?.endStopGrace() }
        }
        let seconds = stopGraceSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.endStopGrace()
        }
    }

    private func endStopGrace() {
        guard graceTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTaskID)
        graceTaskID = .invalid
    }

    private func unfinishedCount() -> Int {
        guard let queue = model?.queue, let counts = try? queue.counts() else { return 0 }
        return counts.pending + counts.running
    }
}

/// Progress for one continued-processing session, in hundredths of a game so the system
/// indicator moves with every analysed move rather than once per game. Several games can be in
/// progress at once, one per engine.
struct SessionProgress: Equatable {
    static let unitsPerGame: Int64 = 100

    /// Games finished (or failed) since the session began.
    private(set) var finished = 0
    /// Games still waiting, excluding those in progress.
    var remaining = 0
    /// How far along each game in progress is.
    private(set) var current: [String: Double] = [:]
    /// The total never shrinks mid-session, so the bar never jumps backwards.
    private var highWaterGames = 0

    init(remaining: Int = 0) {
        self.remaining = remaining
        highWaterGames = remaining
    }

    var totalGames: Int {
        max(highWaterGames, finished + remaining + current.count)
    }

    var totalUnits: Int64 { Int64(max(1, totalGames)) * Self.unitsPerGame }

    var completedUnits: Int64 {
        let partial = current.values.reduce(Int64(0)) {
            $0 + Int64(($1 * Double(Self.unitsPerGame)).rounded(.down))
        }
        return Int64(finished) * Self.unitsPerGame + partial
    }

    mutating func beginGame(gameKey: String) {
        if current[gameKey] == nil, remaining > 0 { remaining -= 1 }
        current[gameKey] = 0
        highWaterGames = totalGames
    }

    mutating func advance(gameKey: String, completed: Int, total: Int) {
        guard current[gameKey] != nil else { return }
        current[gameKey] = total > 0 ? min(1, Double(completed) / Double(total)) : 0
        highWaterGames = totalGames
    }

    mutating func finishGame(gameKey: String) {
        current[gameKey] = nil
        finished += 1
        highWaterGames = totalGames
    }

    /// An interrupted game goes back into the waiting count.
    mutating func interruptGame(gameKey: String) {
        guard current.removeValue(forKey: gameKey) != nil else { return }
        remaining += 1
    }

    func subtitle(label: String?) -> String {
        let done = "\(finished) of \(totalGames) games"
        if current.count > 1 { return "\(done) · \(current.count) at once" }
        guard let label, !current.isEmpty else { return done }
        return "Game \(min(finished + 1, totalGames)) of \(totalGames) · \(label)"
    }
}
