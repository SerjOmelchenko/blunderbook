//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

struct BackupManifest {
    var schema: Int
    var app: String
    var build: String
    var createdAt: Date
    var counts: [String: Int]
    var checksums: [String: String]
}

struct BackupPreview {
    var manifest: BackupManifest
    var newPlayers: [String]
    var existingPlayers: [String]
    var newGames: Int
    var duplicateGames: Int
    var newAnalyses: Int
    var conflictingAnalyses: Int
    var olderPolicyAnalyses: Int
    var totalMoves: Int
    /// Players that arrive without a provider ID, which can never be merged on a name alone.
    var provisionalPlayers: [String]
}

struct ImportResult {
    var playersAdded = 0
    var playersMerged = 0
    var gamesAdded = 0
    var gamesSkipped = 0
    var analysesAdded = 0
    var analysesKept = 0
    var historicalAnalyses = 0
}

enum BackupError: LocalizedError {
    case missingFile(String)
    case unsupportedSchema(Int)
    case checksumMismatch(String)
    case recordTooLarge(String)
    case invalidRecord(String)
    case notEnoughSpace
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "The backup is missing \(name)."
        case .unsupportedSchema(let version): return "This backup uses schema \(version), which this version of the app cannot read."
        case .checksumMismatch(let name): return "The contents of \(name) do not match the manifest."
        case .recordTooLarge(let name): return "A record in \(name) is larger than the 10 MB limit."
        case .invalidRecord(let detail): return "A record could not be read: \(detail)"
        case .notEnoughSpace: return "There is not enough free space to import this backup."
        case .cancelled: return "The import was cancelled."
        }
    }
}

/// Versioned, self-describing `.chessbackup` archives.
///
/// Export writes from one read snapshot; import stages and validates everything *before* the
/// first write, so a damaged or cancelled import leaves the existing database untouched. Nothing
/// about entitlement or window membership is trusted from a file (§10).
final class BackupService {
    /// Version 2 records each player's site. Version 1 backups predate Lichess and are read as
    /// all-Chess.com; a version 1 app refuses a version 2 file rather than mislabel its players.
    static let schemaVersion = 2
    static let readableSchemas: Set<Int> = [1, 2]
    static let fileExtension = "chessbackup"
    private static let maxRecordBytes = 10 * 1024 * 1024

    private let database: SQLiteDatabase
    private let players: PlayerRepository
    private let games: GameRepository
    private let analyses: AnalysisRepository

    init(database: SQLiteDatabase, players: PlayerRepository, games: GameRepository, analyses: AnalysisRepository) {
        self.database = database
        self.players = players
        self.games = games
        self.analyses = analyses
    }

    // MARK: - Export

    /// Includes downloaded PGNs and completed analyses. Never queue state, StoreKit data,
    /// credentials, diagnostics or engine assets (§10).
    func export(to directory: URL, progress: ((Double) -> Void)? = nil) throws -> URL {
        var playerRows: [Data] = []
        var gameRows: [Data] = []
        var membershipRows: [Data] = []
        var analysisRows: [Data] = []
        var moveRows: [Data] = []

        try database.transaction {
            for row in try database.queryUnsafe("SELECT * FROM players;") {
                guard let player = PlayerRepository.player(row) else { continue }
                playerRows.append(try Self.line([
                    "id": player.id.uuidString,
                    "provider": player.provider.rawValue,
                    "providerID": Self.json(player.providerID),
                    "username": player.username,
                    "displayUsername": player.displayUsername,
                    "aliases": player.aliases,
                    "avatarURL": Self.json(player.avatarURL),
                    "country": Self.json(player.country),
                    "title": Self.json(player.title),
                    "createdAt": player.createdAt.timeIntervalSince1970
                ]))
            }
            progress?(0.1)

            for row in try database.queryUnsafe("SELECT * FROM games;") {
                guard let game = GameRepository.game(row) else { continue }
                gameRows.append(try Self.line([
                    "gameKey": game.gameKey, "url": game.url, "uuid": Self.json(game.uuid),
                    "pgn": game.pgn, "startFEN": game.startFEN, "moveHash": game.moveHash,
                    "endTime": game.endTime.timeIntervalSince1970,
                    "timeClass": game.timeClass.rawValue, "timeControl": game.timeControl,
                    "rules": game.rules, "rated": game.rated,
                    "whiteUsername": game.white.username, "whiteRating": Self.json(game.white.rating),
                    "whiteResult": game.white.resultCode,
                    "blackUsername": game.black.username, "blackRating": Self.json(game.black.rating),
                    "blackResult": game.black.resultCode,
                    "eco": Self.json(game.eco), "ecoURL": Self.json(game.ecoURL),
                    "openingName": Self.json(game.openingName),
                    "parseState": game.parseState.rawValue, "plyCount": game.plyCount
                ]))
            }
            progress?(0.4)

            for row in try database.queryUnsafe("SELECT * FROM player_games;") {
                membershipRows.append(try Self.line([
                    "playerID": row.string("player_id") ?? "",
                    "gameKey": row.string("game_key") ?? "",
                    "color": row.int("color") ?? 0,
                    "outcome": row.string("outcome") ?? "unknown"
                ]))
            }
            progress?(0.55)

            // Completed analyses only.
            for row in try database.queryUnsafe("SELECT * FROM analyses WHERE status = 'complete';") {
                guard let id = row.uuid("id") else { continue }
                analysisRows.append(try Self.line([
                    "id": id.uuidString,
                    "gameKey": row.string("game_key") ?? "",
                    "policyID": row.string("policy_id") ?? "",
                    "engineVersion": row.string("engine_version") ?? "",
                    "evaluationVersion": row.string("evaluation_version") ?? "",
                    "scoringVersion": row.string("scoring_version") ?? "",
                    "taggerVersion": row.string("tagger_version") ?? "",
                    "whiteAccuracy": Self.json(row.double("white_accuracy")),
                    "blackAccuracy": Self.json(row.double("black_accuracy")),
                    "createdAt": Self.json(row.date("created_at")?.timeIntervalSince1970),
                    "completedAt": Self.json(row.date("completed_at")?.timeIntervalSince1970)
                ]))

                for move in try analyses.moves(analysisID: id) {
                    moveRows.append(try Self.line([
                        "analysisID": id.uuidString, "ply": move.ply, "mover": move.mover.rawValue,
                        "san": move.san, "uci": move.uci, "fenBefore": move.fenBefore,
                        "scoreBefore": move.scoreBefore.storageText, "scoreAfter": move.scoreAfter.storageText,
                        "lineSAN": move.lineSAN, "lineUCI": move.lineUCI,
                        "depth": move.depth, "nodes": move.nodes,
                        "labels": Self.json(move.labels.map(Self.labelsRecord))
                    ]))
                }
            }
            progress?(0.85)
        }

        func joined(_ rows: [Data]) -> Data {
            var data = Data()
            for row in rows { data.append(row); data.append(0x0A) }
            return data
        }

        let files: [(String, Data)] = [
            ("players.ndjson", joined(playerRows)),
            ("games.ndjson", joined(gameRows)),
            ("player-games.ndjson", joined(membershipRows)),
            ("analyses.ndjson", joined(analysisRows)),
            ("moves.ndjson", joined(moveRows))
        ]

        var checksums: [String: String] = [:]
        for (name, data) in files { checksums[name] = GameIdentity.sha256(data: data) }

        let manifest: [String: Any] = [
            "schema": Self.schemaVersion,
            "app": "Blunderbook",
            "build": "\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "counts": [
                "players": playerRows.count,
                "games": gameRows.count,
                "playerGames": membershipRows.count,
                "analyses": analysisRows.count,
                "moves": moveRows.count
            ],
            "checksums": checksums
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = directory.appendingPathComponent("Blunderbook-\(formatter.string(from: Date())).\(Self.fileExtension)")

        var entries = [ZipArchive.Entry(name: "manifest.json", data: manifestData)]
        entries.append(contentsOf: files.map { ZipArchive.Entry(name: $0.0, data: $0.1) })
        try ZipArchive.write(entries: entries, to: url)
        progress?(1)
        return url
    }

    // MARK: - Import

    struct StagedBackup {
        var manifest: BackupManifest
        var players: [[String: Any]]
        var games: [[String: Any]]
        var memberships: [[String: Any]]
        var analyses: [[String: Any]]
        var moves: [[String: Any]]
    }

    /// Reads and fully validates the archive without touching the database.
    func stage(url: URL) throws -> StagedBackup {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let entries = try ZipArchive.read(url: url)
        var byName: [String: Data] = [:]
        for entry in entries { byName[entry.name] = entry.data }

        guard let manifestData = byName["manifest.json"] else { throw BackupError.missingFile("manifest.json") }
        guard let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let schema = object["schema"] as? Int else {
            throw BackupError.invalidRecord("manifest.json is not readable")
        }
        guard Self.readableSchemas.contains(schema) else { throw BackupError.unsupportedSchema(schema) }

        let checksums = (object["checksums"] as? [String: String]) ?? [:]
        let manifest = BackupManifest(schema: schema,
                                      app: (object["app"] as? String) ?? "Unknown",
                                      build: (object["build"] as? String) ?? "",
                                      createdAt: ISO8601DateFormatter().date(from: (object["createdAt"] as? String) ?? "") ?? Date(),
                                      counts: (object["counts"] as? [String: Int]) ?? [:],
                                      checksums: checksums)

        func records(_ name: String) throws -> [[String: Any]] {
            guard let data = byName[name] else { throw BackupError.missingFile(name) }
            if let expected = checksums[name], GameIdentity.sha256(data: data) != expected {
                throw BackupError.checksumMismatch(name)
            }
            var result: [[String: Any]] = []
            for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard line.count <= Self.maxRecordBytes else { throw BackupError.recordTooLarge(name) }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw BackupError.invalidRecord("bad line in \(name)")
                }
                result.append(object)
            }
            return result
        }

        let staged = StagedBackup(manifest: manifest,
                                  players: try records("players.ndjson"),
                                  games: try records("games.ndjson"),
                                  memberships: try records("player-games.ndjson"),
                                  analyses: try records("analyses.ndjson"),
                                  moves: try records("moves.ndjson"))

        // Counts must match the manifest before anything is trusted.
        if let declared = manifest.counts["games"], declared != staged.games.count {
            throw BackupError.invalidRecord("games count does not match the manifest")
        }
        if let declared = manifest.counts["analyses"], declared != staged.analyses.count {
            throw BackupError.invalidRecord("analysis count does not match the manifest")
        }
        // Foreign keys inside the archive.
        let gameKeys = Set(staged.games.compactMap { $0["gameKey"] as? String })
        for analysis in staged.analyses {
            guard let key = analysis["gameKey"] as? String, gameKeys.contains(key) else {
                throw BackupError.invalidRecord("an analysis refers to a game that is not in the backup")
            }
        }
        let estimated = Int64(staged.games.count) * 4_096 + Int64(staged.moves.count) * 512
        guard DeviceConditionsMonitor.availableDiskBytes() > estimated + 100 * 1024 * 1024 else {
            throw BackupError.notEnoughSpace
        }
        return staged
    }

    func preview(_ staged: StagedBackup) throws -> BackupPreview {
        var newPlayers: [String] = []
        var existingPlayers: [String] = []
        var provisional: [String] = []

        for record in staged.players {
            let username = (record["displayUsername"] as? String) ?? (record["username"] as? String) ?? "?"
            let providerID = record["providerID"] as? String
            if let providerID, let existing = try players.player(providerID: providerID) {
                existingPlayers.append(existing.displayUsername)
            } else {
                if providerID == nil { provisional.append(username) }
                newPlayers.append(username)
            }
        }

        var newGames = 0
        var duplicates = 0
        for record in staged.games {
            guard let key = record["gameKey"] as? String else { continue }
            if (try games.game(key: key)) != nil { duplicates += 1 } else { newGames += 1 }
        }

        var newAnalyses = 0
        var conflicts = 0
        var historical = 0
        for record in staged.analyses {
            guard let key = record["gameKey"] as? String, let policy = record["policyID"] as? String else { continue }
            if try keepsExistingReview(gameKey: key, incomingPolicy: policy) {
                conflicts += 1
            } else if policy == AnalysisPolicy.identifier || DeepReview.isDeep(policyID: policy) {
                newAnalyses += 1
            } else {
                historical += 1
            }
        }

        return BackupPreview(manifest: staged.manifest,
                             newPlayers: newPlayers,
                             existingPlayers: existingPlayers,
                             newGames: newGames,
                             duplicateGames: duplicates,
                             newAnalyses: newAnalyses,
                             conflictingAnalyses: conflicts,
                             olderPolicyAnalyses: historical,
                             totalMoves: staged.moves.count,
                             provisionalPlayers: provisional)
    }

    /// Merge-only commit in one transaction. Existing complete analyses win on conflict, and
    /// PGNs are re-validated locally rather than trusted (§10).
    func commit(_ staged: StagedBackup) throws -> ImportResult {
        var result = ImportResult()
        var playerIDMap: [String: UUID] = [:]

        var movesByAnalysis: [String: [[String: Any]]] = [:]
        for move in staged.moves {
            guard let id = move["analysisID"] as? String else { continue }
            movesByAnalysis[id, default: []].append(move)
        }

        try database.transaction {
            for record in staged.players {
                guard let sourceID = record["id"] as? String,
                      let username = record["username"] as? String else { continue }
                let providerID = record["providerID"] as? String
                let display = (record["displayUsername"] as? String) ?? username
                let provider = Provider(rawValue: (record["provider"] as? String) ?? "") ?? .chessCom

                if let providerID, let existing = try players.player(providerID: providerID) {
                    playerIDMap[sourceID] = existing.id
                    result.playersMerged += 1
                    continue
                }
                if let existing = try players.player(username: username, provider: provider), existing.providerID == nil, providerID == nil {
                    // Two provisional identities with the same name still do not merge silently;
                    // the local one simply keeps its own row and the backup one is skipped.
                    playerIDMap[sourceID] = existing.id
                    result.playersMerged += 1
                    continue
                }
                var player = TrackedPlayer(provider: provider,
                                           providerID: providerID,
                                           username: username.lowercased(),
                                           displayUsername: display)
                player.aliases = (record["aliases"] as? [String]) ?? []
                player.avatarURL = record["avatarURL"] as? String
                player.country = record["country"] as? String
                player.title = record["title"] as? String
                // An imported player has no locally verified window until a refresh succeeds.
                player.hasVerifiedWindow = false
                player.status = .never
                try players.save(player)
                playerIDMap[sourceID] = player.id
                result.playersAdded += 1
            }

            var importedGames: [GameRecord] = []
            for record in staged.games {
                guard let key = record["gameKey"] as? String, let pgn = record["pgn"] as? String else { continue }
                if try games.game(key: key) != nil { result.gamesSkipped += 1; continue }
                // Independently validate the PGN rather than trusting the file's own claims.
                let parsed = PGNParser.parse(pgn)
                let timeClass = TimeClass(rawValue: (record["timeClass"] as? String) ?? "") ?? .rapid
                let game = GameRecord(gameKey: key,
                                      url: (record["url"] as? String) ?? "",
                                      uuid: record["uuid"] as? String,
                                      pgn: pgn,
                                      startFEN: parsed.startFEN,
                                      moveHash: GameIdentity.moveHash(startFEN: parsed.startFEN, moves: parsed.moves),
                                      endTime: Date(timeIntervalSince1970: (record["endTime"] as? Double) ?? 0),
                                      timeClass: timeClass,
                                      timeControl: (record["timeControl"] as? String) ?? "",
                                      rules: (record["rules"] as? String) ?? "chess",
                                      rated: (record["rated"] as? Bool) ?? false,
                                      white: GameSide(username: (record["whiteUsername"] as? String) ?? "",
                                                      rating: record["whiteRating"] as? Int,
                                                      resultCode: (record["whiteResult"] as? String) ?? ""),
                                      black: GameSide(username: (record["blackUsername"] as? String) ?? "",
                                                      rating: record["blackRating"] as? Int,
                                                      resultCode: (record["blackResult"] as? String) ?? ""),
                                      eco: record["eco"] as? String,
                                      ecoURL: record["ecoURL"] as? String,
                                      openingName: record["openingName"] as? String,
                                      parseState: parsed.isValid ? .parsed : .malformed,
                                      plyCount: parsed.moves.count)
                importedGames.append(game)
                result.gamesAdded += 1
            }
            try games.upsert(importedGames)

            for record in staged.memberships {
                guard let sourceID = record["playerID"] as? String,
                      let playerID = playerIDMap[sourceID],
                      let key = record["gameKey"] as? String,
                      let colorValue = record["color"] as? Int,
                      let color = PieceColor(rawValue: colorValue),
                      let game = try games.game(key: key) else { continue }
                try games.link(playerID: playerID, game: game, color: color)
            }

            for record in staged.analyses {
                guard let sourceID = record["id"] as? String,
                      let key = record["gameKey"] as? String,
                      let policy = record["policyID"] as? String else { continue }
                if try keepsExistingReview(gameKey: key, incomingPolicy: policy) {
                    result.analysesKept += 1
                    continue
                }
                let provenance = AnalysisProvenance(policyID: policy,
                                                    engineVersion: (record["engineVersion"] as? String) ?? "",
                                                    evaluationVersion: (record["evaluationVersion"] as? String) ?? "",
                                                    scoringVersion: (record["scoringVersion"] as? String) ?? "",
                                                    taggerVersion: (record["taggerVersion"] as? String) ?? "")
                var analysis = GameAnalysis(gameKey: key, provenance: provenance, status: .complete, nextPly: 0,
                                            whiteAccuracy: record["whiteAccuracy"] as? Double,
                                            blackAccuracy: record["blackAccuracy"] as? Double)
                analysis.completedAt = (record["completedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                analysis.moves = (movesByAnalysis[sourceID] ?? []).compactMap(Self.move).sorted { $0.ply < $1.ply }
                analysis.nextPly = analysis.moves.count
                try analyses.save(analysis)
                if policy == AnalysisPolicy.identifier || DeepReview.isDeep(policyID: policy) {
                    result.analysesAdded += 1
                } else {
                    result.historicalAnalyses += 1
                }
            }
        }
        return result
    }

    /// A game that already has a complete review keeps it, whatever either policy, unless the
    /// backup holds a deep review and the game does not.
    private func keepsExistingReview(gameKey: String, incomingPolicy: String) throws -> Bool {
        guard let existing = try analyses.header(gameKey: gameKey), existing.status == .complete else { return false }
        return !DeepReview.isDeep(policyID: incomingPolicy) || DeepReview.isDeep(policyID: existing.policyID)
    }

    private static func labelsRecord(_ labels: MoveLabels) -> [String: Any] {
        [
            "bestMoveSAN": json(labels.bestMoveSAN),
            "bestLineSAN": labels.bestLineSAN, "bestLineUCI": labels.bestLineUCI,
            "confirmed": labels.confirmed, "loss": labels.loss, "accuracy": labels.accuracy,
            "severity": json(labels.severity?.rawValue), "phase": labels.phase.rawValue,
            "tags": labels.tags.map(\.rawValue), "consequence": labels.consequence.rawValue,
            "explanation": labels.explanation, "isBest": labels.isBest
        ].filter { !($0.value is NSNull) }
    }

    private static func labels(_ record: [String: Any]?) -> MoveLabels? {
        guard let record else { return nil }
        return MoveLabels(bestMoveSAN: record["bestMoveSAN"] as? String,
                          bestLineSAN: (record["bestLineSAN"] as? [String]) ?? [],
                          bestLineUCI: (record["bestLineUCI"] as? [String]) ?? [],
                          confirmed: (record["confirmed"] as? Bool) ?? false,
                          loss: (record["loss"] as? Double) ?? 0,
                          accuracy: (record["accuracy"] as? Double) ?? 0,
                          severity: (record["severity"] as? String).flatMap(Severity.init(rawValue:)),
                          phase: GamePhase(rawValue: (record["phase"] as? String) ?? "middlegame") ?? .middlegame,
                          tags: ((record["tags"] as? [String]) ?? []).compactMap(PatternTag.init(rawValue:)),
                          consequence: Consequence(rawValue: (record["consequence"] as? String) ?? "") ?? .evaluationLoss,
                          explanation: (record["explanation"] as? String) ?? "",
                          isBest: (record["isBest"] as? Bool) ?? false)
    }

    private static func move(_ record: [String: Any]) -> MoveAnalysis? {
        guard let ply = record["ply"] as? Int,
              let moverValue = record["mover"] as? Int,
              let mover = PieceColor(rawValue: moverValue) else { return nil }
        return MoveAnalysis(ply: ply,
                            mover: mover,
                            san: (record["san"] as? String) ?? "",
                            uci: (record["uci"] as? String) ?? "",
                            fenBefore: (record["fenBefore"] as? String) ?? ChessBoard.startFEN,
                            scoreBefore: EngineScore.fromStorage((record["scoreBefore"] as? String) ?? ""),
                            scoreAfter: EngineScore.fromStorage((record["scoreAfter"] as? String) ?? ""),
                            // Backups written before eval-v1 call the line after the move its reply line.
                            lineSAN: (record["lineSAN"] as? [String]) ?? (record["replyLineSAN"] as? [String]) ?? [],
                            lineUCI: (record["lineUCI"] as? [String]) ?? (record["replyLineUCI"] as? [String]) ?? [],
                            depth: (record["depth"] as? Int) ?? 0,
                            nodes: (record["nodes"] as? Int) ?? 0,
                            labels: labels(record["labels"] as? [String: Any]))
    }

    /// Boxes an optional so a missing value becomes an omitted JSON key rather than a nested
    /// `Optional` sneaking into the payload.
    private static func json<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        let cleaned = object.filter { !($0.value is NSNull) }
        return try JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys])
    }
}
