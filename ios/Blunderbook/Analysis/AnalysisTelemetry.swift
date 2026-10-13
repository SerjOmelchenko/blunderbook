//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// A local performance log for tuning bulk analysis on real phones.
///
/// It records where the time goes — searching, blocked, suspended — next to the device conditions
/// at the time, as JSON lines in Application Support. Nothing is sent anywhere: the file is read
/// over USB with `scripts/telemetry-pull.sh`. It holds no usernames or game identities, only
/// counts and timings.
///
/// Each engine records through its own `Channel`, so a sample shows every engine's speed and each
/// game's line shows only that game's work. Counters are filled from the engines' threads and
/// drained by the coordinator's sampler, so every sample describes the interval since the one
/// before it.
final class AnalysisTelemetry: @unchecked Sendable {

    /// Searches at one node budget, or by one engine.
    struct SearchCounters: Codable {
        var searches = 0
        var seconds = 0.0
        var nodes = 0
    }

    /// Work done in one interval, or over one game.
    struct Counters: Codable {
        var budgets: [String: SearchCounters] = [:]
        var engines: [String: SearchCounters] = [:]
        var plies = 0

        mutating func addSearch(engine: String, budget: Int, seconds: Double, nodes: Int) {
            budgets[String(budget), default: SearchCounters()].searches += 1
            budgets[String(budget), default: SearchCounters()].seconds += seconds
            budgets[String(budget), default: SearchCounters()].nodes += nodes
            engines[engine, default: SearchCounters()].searches += 1
            engines[engine, default: SearchCounters()].seconds += seconds
            engines[engine, default: SearchCounters()].nodes += nodes
        }
    }

    /// Device, engine and queue state, captured on the main actor at each sample.
    struct Conditions: Codable {
        var thermal: String
        var battery: Double?
        var charging: Bool
        var lowPower: Bool
        /// The engines bulk work may use, such as "P+2E" or "2E".
        var engines: String
        var blockers: [String]
        var pausedByUser: Bool
        var suspendedForBackground: Bool
        var appState: String
        var activeGames: Int
        var pendingGames: Int
        var pendingPlies: Int
    }

    /// One engine's view of the log. Its work counts towards the shared interval and towards the
    /// game that engine is analysing.
    final class Channel: @unchecked Sendable {
        let name: String
        private unowned let log: AnalysisTelemetry
        private let lock = NSLock()
        private var game = Counters()
        private var gameStarted: Date?

        fileprivate init(name: String, log: AnalysisTelemetry) {
            self.name = name
            self.log = log
        }

        func recordSearch(budget: Int, seconds: Double, nodes: Int) {
            update { $0.addSearch(engine: name, budget: budget, seconds: seconds, nodes: nodes) }
        }

        func recordPly() {
            update { $0.plies += 1 }
        }

        func gameStarted(plies: Int, bulk: Bool) {
            lock.lock()
            game = Counters()
            gameStarted = Date()
            lock.unlock()
            log.write(["event": "gameStarted", "engine": name, "plies": plies, "bulk": bulk])
        }

        /// `outcome` is finished, failed or interrupted.
        func gameEnded(outcome: String) {
            lock.lock()
            let counters = game
            let seconds = gameStarted.map { Date().timeIntervalSince($0) } ?? 0
            gameStarted = nil
            lock.unlock()
            log.write(["event": "gameEnded", "engine": name, "outcome": outcome, "seconds": seconds,
                       "work": log.encodable(counters)])
        }

        func event(_ name: String) {
            log.event(name, ["engine": self.name])
        }

        private func update(_ body: (inout Counters) -> Void) {
            log.updateInterval(body)
            lock.lock()
            if gameStarted != nil { body(&game) }
            lock.unlock()
        }
    }

    static let fileName = "telemetry.jsonl"
    static let rotatedFileName = "telemetry.1.jsonl"
    /// The log is rotated past this size, so at most twice this is ever kept.
    static let maxFileBytes = 8 * 1024 * 1024

    private let lock = NSLock()
    private var interval = Counters()
    private var lastSample = Date()
    private var lastCPUSeconds = AnalysisTelemetry.processCPUSeconds()

    private let directory: URL
    private let writeQueue = DispatchQueue(label: "app.chessanalyser.telemetry")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func channel(_ name: String) -> Channel {
        Channel(name: name, log: self)
    }

    // MARK: - Sampling (main actor)

    /// Writes one line covering everything since the previous sample, then starts a new interval.
    func sample(_ conditions: Conditions) {
        lock.lock()
        let counters = interval
        interval = Counters()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample)
        lastSample = now
        lock.unlock()

        let cpu = Self.processCPUSeconds()
        let cpuSeconds = cpu - lastCPUSeconds
        lastCPUSeconds = cpu

        write(["event": "sample",
               "interval": elapsed,
               "cpuSeconds": cpuSeconds,
               "conditions": encodable(conditions),
               "work": encodable(counters)])
    }

    /// Something worth a line of its own: launch, pause, a change of background state.
    func event(_ name: String, _ details: [String: Any] = [:]) {
        var line = details
        line["event"] = name
        write(line)
    }

    /// Waits until every line recorded so far is on disk.
    func flush() {
        writeQueue.sync {}
    }

    // MARK: - Private

    fileprivate func updateInterval(_ body: (inout Counters) -> Void) {
        lock.lock()
        body(&interval)
        lock.unlock()
    }

    fileprivate func encodable<T: Encodable>(_ value: T) -> Any {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    fileprivate func write(_ fields: [String: Any]) {
        var line = fields
        line["t"] = Date().timeIntervalSince1970
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        let url = fileURL
        let rotated = directory.appendingPathComponent(Self.rotatedFileName)
        writeQueue.async {
            let files = FileManager.default
            if let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxFileBytes {
                try? files.removeItem(at: rotated)
                try? files.moveItem(at: url, to: rotated)
            }
            if !files.fileExists(atPath: url.path) {
                files.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// User plus system CPU time of the whole process. Its change over an interval, divided by
    /// the interval, is how many cores the app kept busy.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
