//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Transactional, versioned migrations. Each migration is applied inside one transaction and the
/// user version is only advanced when it commits, so an interrupted upgrade re-runs cleanly.
enum Schema {
    static let currentVersion = 4

    static func migrate(_ database: SQLiteDatabase) throws {
        var version = try database.userVersion()
        while version < currentVersion {
            let next = version + 1
            try database.transaction {
                try database.executeUnsafe(sql(for: next))
                try database.executeUnsafe("PRAGMA user_version = \(next);")
            }
            version = next
        }
    }

    private static func sql(for version: Int) -> String {
        switch version {
        case 1: return version1
        case 2: return version2
        case 3: return version3
        case 4: return version4
        default: return ""
        }
    }

    /// The search cache (opening positions shared between games) saved about 3% of the work and is
    /// dropped now that several engines analyse games side by side. The timing samples described a
    /// single engine, so the estimate starts measuring afresh.
    private static let version4 = """
    DROP TABLE IF EXISTS search_cache;
    DELETE FROM timing_samples;
    """

    /// Root searches shared between games (the policy standard-v2 search cache). Derived data only: losing it costs
    /// time, never results, so it is not part of a backup.
    private static let version3 = """
    CREATE TABLE search_cache (
        key TEXT PRIMARY KEY,
        configuration TEXT NOT NULL,
        score TEXT NOT NULL,
        best_move TEXT NOT NULL,
        line TEXT NOT NULL DEFAULT '',
        depth INTEGER NOT NULL,
        nodes INTEGER NOT NULL,
        used_at REAL NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX search_cache_used ON search_cache(used_at);
    """

    /// Per-player analysis allowances (the free plan is a quota, not only a window) and the
    /// record of which bucket paid for each queued job, so a cancellation or failure refunds the
    /// one that was actually charged.
    private static let version2 = """
    CREATE TABLE player_allowances (
        player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
        window_grant_used INTEGER NOT NULL DEFAULT 0,
        daily_credits INTEGER NOT NULL DEFAULT 0,
        last_accrual_day TEXT NOT NULL,
        created_day TEXT NOT NULL
    );

    ALTER TABLE queue_items ADD COLUMN charged_bucket TEXT NOT NULL DEFAULT 'none';
    ALTER TABLE queue_items ADD COLUMN player_id TEXT;
    """

    private static let version1 = """
    CREATE TABLE players (
        id TEXT PRIMARY KEY,
        provider_id TEXT UNIQUE,
        username TEXT NOT NULL,
        display_username TEXT NOT NULL,
        aliases TEXT NOT NULL DEFAULT '',
        avatar_url TEXT,
        country TEXT,
        title TEXT,
        last_checked REAL,
        last_success REAL,
        status TEXT NOT NULL DEFAULT 'never',
        created_at REAL NOT NULL,
        verified_window INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX players_username ON players(username);

    CREATE TABLE archives (
        player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        year INTEGER NOT NULL,
        month INTEGER NOT NULL,
        url TEXT NOT NULL,
        etag TEXT,
        last_modified TEXT,
        fetched_at REAL,
        expires_at REAL,
        complete INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (player_id, year, month)
    );

    CREATE TABLE games (
        game_key TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        uuid TEXT,
        pgn TEXT NOT NULL,
        start_fen TEXT NOT NULL,
        move_hash TEXT NOT NULL,
        end_time REAL NOT NULL,
        time_class TEXT NOT NULL,
        time_control TEXT NOT NULL,
        rules TEXT NOT NULL,
        rated INTEGER NOT NULL,
        white_username TEXT NOT NULL,
        white_rating INTEGER,
        white_result TEXT NOT NULL,
        black_username TEXT NOT NULL,
        black_rating INTEGER,
        black_result TEXT NOT NULL,
        eco TEXT,
        eco_url TEXT,
        opening_name TEXT,
        parse_state TEXT NOT NULL,
        ply_count INTEGER NOT NULL
    );
    CREATE INDEX games_end_time ON games(end_time DESC);

    CREATE TABLE player_games (
        player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        game_key TEXT NOT NULL REFERENCES games(game_key) ON DELETE CASCADE,
        color INTEGER NOT NULL,
        outcome TEXT NOT NULL,
        in_window INTEGER NOT NULL DEFAULT 0,
        window_version INTEGER NOT NULL DEFAULT 0,
        end_time REAL NOT NULL,
        time_class TEXT NOT NULL,
        rated INTEGER NOT NULL,
        rating INTEGER,
        opening_name TEXT,
        PRIMARY KEY (player_id, game_key)
    );
    CREATE INDEX player_games_class ON player_games(player_id, time_class, end_time DESC);
    CREATE INDEX player_games_window ON player_games(player_id, in_window, end_time DESC);
    CREATE INDEX player_games_game ON player_games(game_key);

    CREATE TABLE analyses (
        id TEXT PRIMARY KEY,
        game_key TEXT NOT NULL REFERENCES games(game_key) ON DELETE CASCADE,
        policy_id TEXT NOT NULL,
        engine_version TEXT NOT NULL,
        evaluation_version TEXT NOT NULL,
        scoring_version TEXT NOT NULL,
        tagger_version TEXT NOT NULL,
        status TEXT NOT NULL,
        next_ply INTEGER NOT NULL DEFAULT 0,
        white_accuracy REAL,
        black_accuracy REAL,
        created_at REAL NOT NULL,
        completed_at REAL,
        error TEXT,
        UNIQUE (game_key, policy_id)
    );
    CREATE INDEX analyses_policy_status ON analyses(policy_id, status);
    CREATE INDEX analyses_completed ON analyses(completed_at DESC);

    CREATE TABLE move_analyses (
        analysis_id TEXT NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
        ply INTEGER NOT NULL,
        mover INTEGER NOT NULL,
        san TEXT NOT NULL,
        uci TEXT NOT NULL,
        fen_before TEXT NOT NULL,
        score_before TEXT NOT NULL,
        score_after TEXT NOT NULL,
        best_move_san TEXT,
        best_line_san TEXT NOT NULL DEFAULT '',
        best_line_uci TEXT NOT NULL DEFAULT '',
        reply_line_san TEXT NOT NULL DEFAULT '',
        reply_line_uci TEXT NOT NULL DEFAULT '',
        depth INTEGER NOT NULL DEFAULT 0,
        nodes INTEGER NOT NULL DEFAULT 0,
        confirmed INTEGER NOT NULL DEFAULT 0,
        loss REAL NOT NULL,
        accuracy REAL NOT NULL,
        severity TEXT,
        phase TEXT NOT NULL,
        consequence TEXT NOT NULL,
        explanation TEXT NOT NULL DEFAULT '',
        is_best INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (analysis_id, ply)
    );
    CREATE INDEX move_analyses_severity ON move_analyses(severity, phase);

    CREATE TABLE move_tags (
        analysis_id TEXT NOT NULL,
        ply INTEGER NOT NULL,
        mover INTEGER NOT NULL,
        tag TEXT NOT NULL,
        PRIMARY KEY (analysis_id, ply, tag),
        FOREIGN KEY (analysis_id, ply) REFERENCES move_analyses(analysis_id, ply) ON DELETE CASCADE
    );
    CREATE INDEX move_tags_tag ON move_tags(tag);

    CREATE TABLE analysis_summaries (
        analysis_id TEXT NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
        game_key TEXT NOT NULL,
        policy_id TEXT NOT NULL,
        color INTEGER NOT NULL,
        moves INTEGER NOT NULL,
        accuracy REAL,
        inaccuracies INTEGER NOT NULL DEFAULT 0,
        mistakes INTEGER NOT NULL DEFAULT 0,
        blunders INTEGER NOT NULL DEFAULT 0,
        opening_moves INTEGER NOT NULL DEFAULT 0,
        middlegame_moves INTEGER NOT NULL DEFAULT 0,
        endgame_moves INTEGER NOT NULL DEFAULT 0,
        opening_errors INTEGER NOT NULL DEFAULT 0,
        middlegame_errors INTEGER NOT NULL DEFAULT 0,
        endgame_errors INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (analysis_id, color)
    );
    CREATE INDEX analysis_summaries_game ON analysis_summaries(game_key, policy_id, color);

    CREATE TABLE analysis_tag_summaries (
        analysis_id TEXT NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
        game_key TEXT NOT NULL,
        policy_id TEXT NOT NULL,
        color INTEGER NOT NULL,
        tag TEXT NOT NULL,
        count INTEGER NOT NULL,
        PRIMARY KEY (analysis_id, color, tag)
    );
    CREATE INDEX analysis_tag_summaries_game ON analysis_tag_summaries(game_key, policy_id, color, tag);

    CREATE TABLE queue_batches (
        id TEXT PRIMARY KEY,
        player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        cancelled INTEGER NOT NULL DEFAULT 0,
        total_items INTEGER NOT NULL DEFAULT 0,
        label TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE queue_items (
        id TEXT PRIMARY KEY,
        batch_id TEXT NOT NULL REFERENCES queue_batches(id) ON DELETE CASCADE,
        game_key TEXT NOT NULL,
        policy_id TEXT NOT NULL,
        priority INTEGER NOT NULL DEFAULT 100,
        state TEXT NOT NULL,
        checkpoint_ply INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX queue_items_order ON queue_items(state, priority, created_at);
    CREATE UNIQUE INDEX queue_items_active_job ON queue_items(game_key, policy_id)
        WHERE state IN ('pending', 'running');

    CREATE TABLE preferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE timing_samples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        recorded_at REAL NOT NULL,
        plies INTEGER NOT NULL,
        seconds REAL NOT NULL
    );
    """
}
