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

/// Watches the device conditions that gate bulk analysis (§7).
///
/// Blockers compose as a set: clearing one never overrides another, and each threshold has
/// hysteresis so work does not flap on and off at the boundary.
@MainActor
@Observable
final class DeviceConditionsMonitor {
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var batteryLevel: Double?
    private(set) var isCharging = false
    private(set) var isLowPowerMode = false
    private(set) var freeDiskBytes: Int64 = 0

    /// Device-derived blockers. User pause and entitlement are added by the coordinator.
    private(set) var blockers: Set<QueueBlocker> = []

    /// Bulk resumes only after the device has been cool for this long.
    private let thermalRecoverySeconds: TimeInterval = 60
    private var thermalNominalSince: Date?
    private var batteryBlocked = false
    private var storageBlocked = false
    private var timer: Timer?

    static let storagePauseBytes: Int64 = 500 * 1024 * 1024
    static let storageResumeBytes: Int64 = 750 * 1024 * 1024

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func update() {
        let info = ProcessInfo.processInfo
        thermalState = info.thermalState
        isLowPowerMode = info.isLowPowerModeEnabled

        let device = UIDevice.current
        let rawLevel = device.batteryLevel
        // An unknown battery level is reported as unknown, never invented (§7).
        batteryLevel = rawLevel < 0 ? nil : Double(rawLevel)
        isCharging = device.batteryState == .charging || device.batteryState == .full

        freeDiskBytes = Self.availableDiskBytes()

        var result: Set<QueueBlocker> = []

        switch thermalState {
        case .serious, .critical:
            thermalNominalSince = nil
            result.insert(.thermal)
        default:
            if thermalNominalSince == nil { thermalNominalSince = Date() }
            if let since = thermalNominalSince, Date().timeIntervalSince(since) < thermalRecoverySeconds,
               blockers.contains(.thermal) {
                result.insert(.thermal)
            }
        }

        if let level = batteryLevel, !isCharging {
            if level <= 0.20 { batteryBlocked = true }
            else if level >= 0.30 { batteryBlocked = false }
        } else if isCharging {
            batteryBlocked = false
        }
        if batteryBlocked { result.insert(.battery) }

        if isLowPowerMode { result.insert(.lowPower) }

        if freeDiskBytes < Self.storagePauseBytes { storageBlocked = true }
        else if freeDiskBytes >= Self.storageResumeBytes { storageBlocked = false }
        if storageBlocked { result.insert(.storage) }

        blockers = result
    }


    /// True when a single foreground review may run: only heat stops those (§7).
    var allowsForegroundReview: Bool {
        !blockers.contains(.thermal) && !blockers.contains(.storage)
    }

    nonisolated static func availableDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return 0
    }

    var batteryDescription: String {
        guard let batteryLevel else { return "Battery level unknown" }
        return "\(Int(batteryLevel * 100))%\(isCharging ? " · charging" : "")"
    }

    var thermalDescription: String {
        switch thermalState {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }
}

/// How much bulk analysis the phone takes on at each temperature (§7).
///
/// Measured on an iPhone 16 Pro: one engine on a performance core searched about 1.1–1.4M nodes/s
/// and warmed the phone within a minute, while one on an efficiency core searched about 250–300k
/// nodes/s for a small fraction of the power, and four of them together about four times that.
/// So efficiency-core engines carry the bulk work side by side, and one performance-core engine
/// joins them only while the device is cool and the app is on screen. Searches are bounded by nodes, so none of this changes
/// results — only how long they take. A review the person asks for borrows every engine and is not
/// paced: it is short, and someone is waiting for it. Its efficiency-core engines still run below
/// the person's own work.
enum ThermalPacing {
    struct Plan: Equatable {
        /// Whether the first performance-core engine also takes bulk games.
        var performanceBulk: Bool
        /// How many efficiency-core engines run bulk games.
        var efficiencyEngines: Int
    }

    /// - Parameter inBackground: the app is not on screen. Bulk work then stays on the efficiency
    ///   cores whatever the temperature.
    static func plan(thermal: ProcessInfo.ThermalState, efficiencyEngines: Int, inBackground: Bool = false) -> Plan {
        switch thermal {
        case .nominal:
            return Plan(performanceBulk: !inBackground, efficiencyEngines: efficiencyEngines)
        case .fair:
            return Plan(performanceBulk: false, efficiencyEngines: efficiencyEngines)
        case .serious, .critical:
            // Hot: the thermal blocker stops everything; the plan only says so too.
            return Plan(performanceBulk: false, efficiencyEngines: 0)
        @unknown default:
            return Plan(performanceBulk: false, efficiencyEngines: efficiencyEngines)
        }
    }

    /// Engines this device runs, from its own core counts, never a list of models. Analysis always
    /// leaves the person one performance core and half the efficiency cores, so the device stays
    /// usable: `P − 1` performance-core engines (at least one) and `⌊E / 2⌋` efficiency-core ones
    /// (at least one), at most `maximumEngines` in all, performance cores first, and at most one
    /// engine per gibibyte of memory (each needs about 100 MB, and the app shares the device).
    static let performanceEngineCount: Int = engineCounts.performance
    static let efficiencyEngineCount: Int = engineCounts.efficiency

    /// Beyond this a game has too few positions left to share out for more engines to help.
    static let maximumEngines = 8

    static func engineCounts(performanceCores: Int, efficiencyCores: Int, memoryGiB: Int) -> (performance: Int, efficiency: Int) {
        let budget = max(2, min(maximumEngines, memoryGiB))
        let performance = max(1, min(performanceCores - 1, budget - 1))
        let efficiency = max(1, min(efficiencyCores / 2, budget - performance))
        return (performance, efficiency)
    }

    private static let engineCounts: (performance: Int, efficiency: Int) = {
        func cores(_ level: Int) -> Int? {
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let found = sysctlbyname("hw.perflevel\(level).physicalcpu", &count, &size, nil, 0) == 0 && count > 0
            return found ? Int(count) : nil
        }
        let total = ProcessInfo.processInfo.processorCount
        let performance = cores(0) ?? max(1, total / 3)
        return engineCounts(performanceCores: performance,
                            efficiencyCores: cores(1) ?? max(0, total - performance),
                            memoryGiB: Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)))
    }()
}

/// How many efficiency-core engines bulk work may use, learned from how the phone copes.
///
/// It starts at one engine per efficiency core. Each time the phone gets hot while analysing, one
/// engine comes off, so a phone that cannot hold the full set settles on fewer instead of cycling
/// through the heat stop. After a long calm stretch, one engine comes back.
struct EfficiencyEngineLimit: Equatable {
    let maximum: Int
    private(set) var value: Int
    private var calmSince: Date?
    private var wasHot = false

    /// Calm time after which one engine comes back.
    static let recoverySeconds: TimeInterval = 20 * 60

    init(maximum: Int) {
        self.maximum = max(1, maximum)
        value = self.maximum
    }

    mutating func update(thermal: ProcessInfo.ThermalState, isWorking: Bool, now: Date = Date()) {
        let isHot = thermal == .serious || thermal == .critical
        if isHot {
            if !wasHot, isWorking { value = max(1, value - 1) }
            calmSince = nil
        } else if thermal == .nominal {
            let since = calmSince ?? now
            calmSince = since
            if value < maximum, now.timeIntervalSince(since) >= Self.recoverySeconds {
                value += 1
                calmSince = now
            }
        } else {
            calmSince = nil
        }
        wasHot = isHot
    }
}
