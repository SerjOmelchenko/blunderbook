//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// `ChessEngine` backed by Stockfish 19.
///
/// The bridge owns one `Stockfish::Engine`, so this type is a thin translation layer: positions
/// go down as a start FEN plus the real move history (§5 — a FEN alone cannot express repetition
/// or the halfmove clock), and results come back as the app's own `EngineScore`.
///
/// Terminal positions are decided here rather than by the engine, because which draws count is a
/// policy question, not a search question.
final class StockfishEngine: ChessEngine {
    /// Name of the pinned network. Stockfish names its nets after their own hash, so the filename
    /// is the checksum: `nn-1a298aa575a0.nnue` is sha256 `1a298aa575a0…`.
    static let networkName = "nn-1a298aa575a0"

    private let bridge: StockfishBridge
    private let monitorQueue = DispatchQueue(label: "app.chessanalyser.stockfish.monitor")
    /// A single search may not exceed this, per the §5 engine watchdog.
    private let watchdogSeconds: TimeInterval = 30
    /// The watchdog for efficiency-core searches. The system may starve background-priority work
    /// while the phone is busy; that is not an engine fault, and a game must not fail for it. A
    /// confirmation search takes about two seconds there, so this still catches a real hang.
    private let backgroundWatchdogSeconds: TimeInterval = 180
    /// The largest search the two allowances above cover as they are.
    private static let watchdogBaseNodes = 500_000
    private let workloadLock = NSLock()
    private var workload = EngineWorkload.interactive

    let engineIdentifier: String
    let evaluationIdentifier: String
    let searchConfigurationIdentifier: String

    /// Loads the bundled network. Returns nil when it is missing or unreadable, so the caller
    /// can report it and fall back rather than launching into an engine that cannot evaluate.
    /// `hashSizeMiB` defaults to the analysis policy's.
    init?(bundle: Bundle = .main, hashSizeMiB: Int = AnalysisPolicy.hashSizeMiB) {
        guard let path = bundle.path(forResource: Self.networkName, ofType: "nnue") else { return nil }
        let bridge = StockfishBridge(networkPath: path, hashSizeMiB: UInt(hashSizeMiB))
        if bridge.loadError != nil { return nil }
        self.bridge = bridge
        engineIdentifier = StockfishBridge.engineVersion
        evaluationIdentifier = bridge.networkVersion
        // The bridge fixes every other option (one thread, single PV, full strength).
        searchConfigurationIdentifier = "threads-1+hash-\(hashSizeMiB)"
    }

    /// Why the engine could not be created, for the caller to surface.
    static func unavailableReason(bundle: Bundle = .main) -> String? {
        guard let path = bundle.path(forResource: networkName, ofType: "nnue") else {
            return "The Stockfish network is not in the app bundle."
        }
        let bridge = StockfishBridge(networkPath: path, hashSizeMiB: UInt(AnalysisPolicy.hashSizeMiB))
        return bridge.loadError
    }

    // MARK: - ChessEngine

    func setWorkload(_ workload: EngineWorkload) {
        workloadLock.lock()
        self.workload = workload
        workloadLock.unlock()
        switch workload {
        case .interactive: bridge.searchPriority = .interactive
        // Measured on an iPhone 16 Pro: utility QoS searched about 355k nodes/s, user-initiated
        // about 1.4M. Pacing, not the scheduler, is what keeps bulk work cool.
        case .bulk: bridge.searchPriority = .interactive
        case .bulkCool: bridge.searchPriority = .utility  // EXPERIMENT: background QoS was throttled to ~75k n/s per engine on the phone
        }
    }

    /// The quality-of-service class the last search ran at. For verification only.
    var lastSearchQoSClass: qos_class_t {
        qos_class_t(rawValue: UInt32(bridge.lastSearchQoSClass))
    }

    func newGame() {
        bridge.clearMemory()
    }

    func search(board: ChessBoard, nodeBudget: Int, cancellation: CancellationToken) -> SearchResult {
        if let terminal = Self.terminalScore(for: board) {
            return .terminal(terminal)
        }
        if cancellation.isCancelled {
            return SearchResult(score: .centipawns(0), bestMove: board.legalMoves().first,
                                principalVariation: [], nodes: 0, depth: 0, isTerminal: false,
                                isComplete: false)
        }

        // Stop the search if the work is cancelled or the watchdog expires. Searches are short,
        // so one poller per search costs little and keeps cancellation responsive.
        let finished = CancellationToken()
        let interrupted = CancellationToken()
        workloadLock.lock()
        let baseAllowance = workload == .bulkCool ? backgroundWatchdogSeconds : watchdogSeconds
        workloadLock.unlock()
        // The allowances were set for searches of up to `watchdogBaseNodes`; a deeper review's
        // larger budget gets proportionally longer before it counts as a hang.
        let allowance = baseAllowance * max(1, Double(nodeBudget) / Double(Self.watchdogBaseNodes))
        let deadline = Date().addingTimeInterval(allowance)
        let bridge = self.bridge
        monitorQueue.async {
            while !finished.isCancelled {
                if cancellation.isCancelled || Date() > deadline {
                    // Marked before stopping, so a search the poller cut short is never
                    // mistaken for one that spent its whole budget.
                    interrupted.cancel()
                    bridge.stop()
                    return
                }
                usleep(40_000)
            }
        }

        let outcome = bridge.search(fromFEN: board.initialFEN,
                                    moves: board.playedMoves.map(\.uci),
                                    nodeBudget: UInt(max(1, nodeBudget)),
                                    clearingFirst: false)
        finished.cancel()

        guard let outcome else {
            // The engine is unusable; return a legal move rather than nothing so the caller's
            // retry-then-fail path stays in charge.
            return SearchResult(score: .centipawns(0), bestMove: board.legalMoves().first,
                                principalVariation: [], nodes: 0, depth: 0, isTerminal: false,
                                isComplete: false)
        }

        let moves = outcome.principalVariation.compactMap(Move.fromUCI)
        let legalLine = Self.legalPrefix(of: moves, from: board)

        return SearchResult(score: Self.score(from: outcome),
                            bestMove: outcome.bestMove.flatMap(Move.fromUCI) ?? legalLine.first,
                            principalVariation: Array(legalLine.prefix(AnalysisPolicy.maxStoredPVPlies)),
                            nodes: Int(outcome.nodes),
                            depth: outcome.depth,
                            isTerminal: false,
                            isComplete: !interrupted.isCancelled)
    }

    // MARK: - Live lines

    /// The best `count` lines from the board's position, best first, each scored from the side
    /// to move. Not part of any analysis policy: these are shown, never stored.
    func searchLines(board: ChessBoard, nodeBudget: Int, count: Int,
                     cancellation: CancellationToken) -> [SearchResult] {
        if Self.terminalScore(for: board) != nil || cancellation.isCancelled { return [] }

        let finished = CancellationToken()
        let bridge = self.bridge
        monitorQueue.async {
            while !finished.isCancelled {
                if cancellation.isCancelled { bridge.stop(); return }
                usleep(30_000)
            }
        }
        let outcomes = bridge.searchLines(fromFEN: board.initialFEN,
                                          moves: board.playedMoves.map(\.uci),
                                          nodeBudget: UInt(max(1, nodeBudget)),
                                          lineCount: UInt(max(1, count)))
        finished.cancel()
        guard !cancellation.isCancelled else { return [] }

        return outcomes.compactMap { outcome in
            let line = Self.legalPrefix(of: outcome.principalVariation.compactMap(Move.fromUCI), from: board)
            guard let first = line.first else { return nil }
            return SearchResult(score: Self.score(from: outcome), bestMove: first,
                                principalVariation: line, nodes: Int(outcome.nodes),
                                depth: outcome.depth, isTerminal: false)
        }
    }

    // MARK: - Translation

    private static func score(from outcome: SFSearchOutcome) -> EngineScore {
        guard outcome.isMate else { return .centipawns(outcome.centipawns) }
        // Stockfish reports `mate 0` for a position that is already checkmate.
        if outcome.mateInMoves == 0 {
            return .checkmate(perspectiveWon: false)
        }
        return .mate(outcome.mateInMoves)
    }

    /// Keeps only the leading moves that are actually legal. Stockfish's lines are legal, but a
    /// stored line is shown on a real board, so this is checked rather than assumed.
    private static func legalPrefix(of moves: [Move], from board: ChessBoard) -> [Move] {
        let replay = board.copy()
        var result: [Move] = []
        for move in moves {
            guard replay.isLegalMove(move) else { break }
            result.append(move)
            replay.makeMove(move)
        }
        return result
    }

    /// Which positions are over by rule. Shared with the native engine so both engines agree on
    /// terminal scoring regardless of what the search would say.
    static func terminalScore(for board: ChessBoard) -> EngineScore? {
        if !board.hasLegalMove {
            return board.isInCheck ? .checkmate(perspectiveWon: false) : .centipawns(0)
        }
        if board.hasInsufficientMaterial() { return .centipawns(0) }
        if board.halfmoveClock >= 150 { return .centipawns(0) }
        if board.repetitionCount() >= 5 { return .centipawns(0) }
        return nil
    }
}
