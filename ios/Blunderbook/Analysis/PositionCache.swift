//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// One position's search, as a deep review uses it.
struct CachedEvaluation: Equatable, Sendable {
    /// In the frame of the side to move.
    var score: EngineScore
    var bestMoveUCI: String?
    var lineUCI: [String]
    var depth: Int
    var nodes: Int
}

/// Searches a deep review does not need to make again.
///
/// Every search starts from a cleared engine with a fixed node budget, so the same position reached
/// by the same moves always gets the same search from the same engine. A cached search is therefore
/// exactly the one the engine would make, and a review that uses it is identical to one that does
/// not. Only positions in the first `maxPly` moves of a game from the standard start are cached:
/// later, games no longer repeat (measured on 9,831 rapid games: 85% of positions after two moves
/// each had been reached before, 33% after five, none after ten).
///
/// Two sources: the named openings computed in advance by the app's own engine and bundled with
/// the app (`OpeningEvaluations.tsv`, the free levels Quick and Standard), and every early position
/// this device has searched itself, at any level. Both are this engine's own searches, never another
/// site's, so a review never mixes two engines' evaluations.
final class PositionCache: @unchecked Sendable {
    /// Positions after at most this many moves are cached.
    static let maxPly = 16

    private let bundled: BundledOpeningEvaluations
    private let repository: PositionCacheRepository?

    /// Every search made since launch, at any move and from any start, kept in memory only, so a
    /// review stopped part way — by heat, say — picks up where it stopped instead of starting over
    /// and running into the same heat again. Cleared when it grows past `sessionLimit`.
    private let sessionLock = NSLock()
    private var session: [String: CachedEvaluation] = [:]
    static let sessionLimit = 4_000

    init(repository: PositionCacheRepository?, bundled: BundledOpeningEvaluations = .shared) {
        self.repository = repository
        self.bundled = bundled
    }

    /// What identifies an engine's searches: the engine, its network and its settings.
    static func signature(of engine: ChessEngine) -> String {
        "\(engine.engineIdentifier)|\(engine.evaluationIdentifier)|\(engine.searchConfigurationIdentifier)"
    }

    /// The key of the position after `moves` from the standard start.
    static func key(_ moves: some Sequence<Move>) -> String {
        moves.map(\.uci).joined(separator: " ")
    }

    func evaluations(engine: String, nodes: Int, keys: [String]) -> [String: CachedEvaluation] {
        var found = bundled.evaluations(engine: engine, nodes: nodes, keys: keys)
        let missing = keys.filter { found[$0] == nil }
        if let repository, !missing.isEmpty,
           let stored = try? repository.evaluations(engine: engine, nodes: nodes, keys: missing) {
            found.merge(stored) { bundled, _ in bundled }
        }
        return found
    }

    /// This session's searches among `keys` (any length), for a game from `startFEN`.
    func remembered(engine: String, nodes: Int, startFEN: String, keys: [String]) -> [String: CachedEvaluation] {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        var found: [String: CachedEvaluation] = [:]
        for key in keys { found[key] = session["\(engine)|\(nodes)|\(startFEN)|\(key)"] }
        return found
    }

    func remember(engine: String, nodes: Int, startFEN: String, key: String, evaluation: CachedEvaluation) {
        sessionLock.lock()
        if session.count >= Self.sessionLimit { session.removeAll(keepingCapacity: true) }
        session["\(engine)|\(nodes)|\(startFEN)|\(key)"] = evaluation
        sessionLock.unlock()
    }

    /// Remembers searches this device made. Bundled positions are not stored again.
    func store(engine: String, nodes: Int, entries: [(key: String, evaluation: CachedEvaluation)]) {
        let known = bundled.evaluations(engine: engine, nodes: nodes, keys: entries.map(\.key))
        try? repository?.store(engine: engine, nodes: nodes, entries: entries.filter { known[$0.key] == nil })
    }
}

/// The searches of the named openings' positions, made in advance by the app's own engine at the
/// free review levels and bundled as `OpeningEvaluations.tsv`. The first line names the engine they
/// were made with; for any other engine the file is ignored. Then one search per line:
/// `nodes, moves, score, best move, line, depth, searched nodes`, tab-separated, moves in UCI.
final class BundledOpeningEvaluations: @unchecked Sendable {
    static let shared = BundledOpeningEvaluations(url: Bundle.main.url(forResource: "OpeningEvaluations", withExtension: "tsv"))

    private let url: URL?
    private let lock = NSLock()
    private var loaded: (engine: String, byNodes: [Int: [String: CachedEvaluation]])?

    init(url: URL?) { self.url = url }

    func evaluations(engine: String, nodes: Int, keys: [String]) -> [String: CachedEvaluation] {
        let table = load()
        guard table.engine == engine, let byKey = table.byNodes[nodes] else { return [:] }
        var found: [String: CachedEvaluation] = [:]
        for key in keys { found[key] = byKey[key] }
        return found
    }

    /// Read once, on first use.
    private func load() -> (engine: String, byNodes: [Int: [String: CachedEvaluation]]) {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        var result: (engine: String, byNodes: [Int: [String: CachedEvaluation]]) = ("", [:])
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "#engine", fields.count >= 2 {
                    result.engine = fields[1]
                    continue
                }
                guard fields.count == 7, let nodes = Int(fields[0]), let depth = Int(fields[5]),
                      let searched = Int(fields[6]) else { continue }
                result.byNodes[nodes, default: [:]][fields[1]] = CachedEvaluation(
                    score: .fromStorage(fields[2]),
                    bestMoveUCI: fields[3].isEmpty ? nil : fields[3],
                    lineUCI: fields[4].split(separator: " ").map(String.init),
                    depth: depth,
                    nodes: searched)
            }
        }
        loaded = result
        return result
    }
}

extension GameAnalyzer.RootEvaluation {
    init(_ cached: CachedEvaluation) {
        self.init(score: cached.score,
                  bestMove: cached.bestMoveUCI.flatMap(Move.fromUCI),
                  line: cached.lineUCI.compactMap(Move.fromUCI),
                  depth: cached.depth,
                  nodes: cached.nodes)
    }
}

extension CachedEvaluation {
    init(_ root: GameAnalyzer.RootEvaluation) {
        self.init(score: root.score, bestMoveUCI: root.bestMove?.uci, lineUCI: root.line.map(\.uci),
                  depth: root.depth, nodes: root.nodes)
    }
}
