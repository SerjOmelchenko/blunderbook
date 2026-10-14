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

/// Anonymous usage events, sent to PostHog so the developer can see how the app is used: how many
/// people have it open, which screens they visit, how analyses go.
///
/// Events are typed, so nothing free-form — no username, game, position or error text — can be
/// sent. The only identifier is a random ID made on this device and tied to nothing else: not the
/// person, not the device, not their chess accounts. PostHog keeps no profile for it
/// (`$process_person_profile`), does no location lookup, and the project discards IP addresses.
/// On by default; About › Privacy turns it off, which also drops whatever was not yet sent.
///
/// Events are held for a few seconds and sent together, kept on disk if the app goes to the
/// background before they could be sent, and dropped rather than retried forever if PostHog
/// refuses them.
final class UsageAnalytics: @unchecked Sendable {
    static let shared = UsageAnalytics()

    /// Everything the app reports. Properties are counts and fixed names only.
    enum Event {
        case appOpened
        case appBackgrounded
        case screen(String)
        case playerAdded(Provider)
        /// The person asked for a game to be analysed.
        case analysisRequested(depth: ReviewDepth)
        case analysisRefused(AppModel.ReviewRefusal)
        /// An engine began the game. One that is interrupted starts again from the beginning, with
        /// a new start.
        case analysisStarted(depth: ReviewDepth)
        /// Every start ends once: finished, failed, or interrupted (stopped, by heat, the app
        /// going to the background, or the person).
        case analysisEnded(outcome: AnalysisOutcome, seconds: Int, plies: Int, depth: ReviewDepth)
        case purchase(PurchaseOutcome)
        /// The free-trial offer after an analysed game came up, and what the person tapped.
        case trialOfferShown
        case trialOfferAnswered(startedTrial: Bool)
        case refreshFailed(ProviderError)

        var name: String {
            switch self {
            // PostHog's own names, which its mobile dashboards recognise.
            case .appOpened: return "Application Opened"
            case .appBackgrounded: return "Application Backgrounded"
            case .screen: return "$screen"
            case .playerAdded: return "player_added"
            case .analysisRequested: return "analysis_requested"
            case .analysisRefused: return "analysis_refused"
            case .analysisStarted: return "analysis_started"
            case .analysisEnded: return "analysis_ended"
            case .purchase: return "purchase"
            case .trialOfferShown: return "trial_offer_shown"
            case .trialOfferAnswered: return "trial_offer_answered"
            case .refreshFailed: return "refresh_failed"
            }
        }

        var properties: [String: Any] {
            switch self {
            case .appOpened, .appBackgrounded, .trialOfferShown:
                return [:]
            case .screen(let name):
                return ["$screen_name": name]
            case .playerAdded(let provider):
                return ["site": provider.rawValue]
            case .analysisRequested(let depth), .analysisStarted(let depth):
                return ["depth": depth.rawValue]
            case .analysisRefused(let refusal):
                switch refusal {
                case .engineUnavailable: return ["reason": "engine_unavailable"]
                case .noPlayer: return ["reason": "no_player"]
                case .anotherGameAnalysing: return ["reason": "another_game_analysing"]
                }
            case .analysisEnded(let outcome, let seconds, let plies, let depth):
                return ["outcome": outcome.rawValue, "seconds": seconds, "plies": plies, "depth": depth.rawValue]
            case .purchase(let outcome):
                switch outcome {
                case .purchased: return ["outcome": "purchased"]
                case .pending: return ["outcome": "pending"]
                case .cancelled: return ["outcome": "cancelled"]
                case .failed: return ["outcome": "failed"]
                case .unavailable: return ["outcome": "unavailable"]
                }
            case .trialOfferAnswered(let startedTrial):
                return ["choice": startedTrial ? "start_trial" : "not_now"]
            case .refreshFailed(let error):
                switch error {
                case .playerNotFound: return ["kind": "player_not_found"]
                case .archiveUnavailable: return ["kind": "archive_unavailable"]
                case .offline: return ["kind": "offline"]
                case .rateLimited: return ["kind": "rate_limited"]
                case .serverError(let code): return ["kind": "server_error", "status": code]
                case .malformedResponse: return ["kind": "malformed_response"]
                case .cancelled: return ["kind": "cancelled"]
                }
            }
        }
    }

    enum AnalysisOutcome: String {
        case finished, failed, interrupted
    }

    // A project key is meant to ship inside apps: it can only send events, never read them.
    private static let endpoint = URL(string: "https://eu.i.posthog.com/batch/")!
    private static let projectKey = "phc_uzFLokGMBdUCjGhRmcPHAkmFfhC5WPjn8P6gt5aWgP66"
    /// Often enough that the live view is close to live, rarely enough to stay off the radio.
    private static let sendInterval: TimeInterval = 10
    private static let batchLimit = 100
    /// A long stretch offline keeps the most recent events, not an ever-growing file.
    private static let bufferLimit = 1_000

    private let queue = DispatchQueue(label: "blunderbook.usage-analytics")
    private let session: URLSession
    private var enabled = false
    private var distinctID: String?
    private var buffer: [[String: Any]] = []
    private var isSending = false
    private var timer: DispatchSourceTimer?
    private var file: URL?

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Called once at launch. `distinctID` is nil while sharing is off.
    func configure(distinctID: String?, directory: URL) {
        queue.sync {
            file = directory.appendingPathComponent("usage-events.json")
            // A test run launches the app as its host; it must never report.
            let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            apply(distinctID: isTestHost ? nil : distinctID)
        }
    }

    /// Turning sharing off drops everything not yet sent; turning it on starts with a new ID.
    func update(distinctID: String?) {
        queue.async { self.apply(distinctID: distinctID) }
    }

    func track(_ event: Event) {
        let date = Date()
        queue.async {
            guard self.enabled, let distinctID = self.distinctID else { return }
            var properties = Self.commonProperties
            properties.merge(event.properties) { _, new in new }
            self.buffer.append(["event": event.name,
                                "distinct_id": distinctID,
                                "uuid": UUID().uuidString.lowercased(),
                                "timestamp": Self.timestamp(date),
                                "properties": properties])
            if self.buffer.count > Self.bufferLimit { self.buffer.removeFirst(self.buffer.count - Self.bufferLimit) }
        }
    }

    /// Sends what is waiting before the app is suspended, and keeps on disk whatever does not
    /// make it, for the next launch.
    @MainActor
    func flushForBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Usage events") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        queue.async {
            self.persist()
            self.send {
                self.persist()
                DispatchQueue.main.async {
                    guard task != .invalid else { return }
                    UIApplication.shared.endBackgroundTask(task)
                    task = .invalid
                }
            }
        }
    }

    // MARK: - Queue

    private func apply(distinctID: String?) {
        self.distinctID = distinctID
        enabled = distinctID != nil
        if enabled {
            restore()
            startTimer()
        } else {
            timer?.cancel()
            timer = nil
            buffer.removeAll()
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: Self.sendInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.send() }
        timer.resume()
        self.timer = timer
    }

    /// Posts up to one batch. Runs on `queue`; `completion` is called there too.
    private func send(completion: (() -> Void)? = nil) {
        guard enabled, !isSending, !buffer.isEmpty else {
            completion?()
            return
        }
        let batch = Array(buffer.prefix(Self.batchLimit))
        let body: [String: Any] = ["api_key": Self.projectKey,
                                   "sent_at": Self.timestamp(Date()),
                                   "batch": batch]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            // Cannot happen with the properties above; never let one bad event block the rest.
            buffer.removeFirst(batch.count)
            completion?()
            return
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        isSending = true
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.isSending = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Sent, or refused for good: either way these events are done. Offline, a rate
                // limit or a server error keeps them for the next try.
                let isDone = error == nil && (200..<300 ~= status || (400..<500 ~= status && status != 429))
                if isDone, self.buffer.count >= batch.count { self.buffer.removeFirst(batch.count) }
                // A copy kept on disk for the background must not hold events now sent.
                if isDone, self.file.map({ FileManager.default.fileExists(atPath: $0.path) }) == true { self.persist() }
                completion?()
            }
        }.resume()
    }

    private func persist() {
        guard let file else { return }
        if buffer.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONSerialization.data(withJSONObject: buffer) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func restore() {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        try? FileManager.default.removeItem(at: file)
        // Events kept from a launch with an older ID still belong to that ID.
        buffer = saved + buffer
    }

    // MARK: - Properties

    /// What PostHog needs to tell builds, systems and phones apart. Nothing here identifies a
    /// person.
    private static let commonProperties: [String: Any] = {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var properties: [String: Any] = [
            "$lib": "blunderbook-ios",
            "$os": "iOS",
            "$os_name": "iOS",
            "$os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "$device_type": "Mobile",
            "$device_model": deviceModel,
            "$app_version": info["CFBundleShortVersionString"] as? String ?? "?",
            "$app_build": info["CFBundleVersion"] as? String ?? "?",
            "$process_person_profile": false,
            "$geoip_disable": true,
        ]
        #if DEBUG
        properties["build_configuration"] = "debug"
        #else
        properties["build_configuration"] = "release"
        #endif
        #if targetEnvironment(simulator)
        properties["is_simulator"] = true
        #else
        properties["is_simulator"] = false
        #endif
        return properties
    }()

    /// The hardware model, such as "iPhone17,1"; a simulator reports the model it simulates.
    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
