//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
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
    static let currentVersion = 11

    /// - Parameter target: the version to stop at; tests use it to stage older databases.
    static func migrate(_ database: SQLiteDatabase, to target: Int = currentVersion) throws {
        var version = try database.userVersion()
        while version < target {
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
        case 5: return version5
        case 6: return version6
        case 7: return version7
        case 8: return version8
        case 9: return version9
        case 10: return version10
        case 11: return version11
        default: return ""
        }
    }

    /// How each mistake has gone on the Mistakes tab, for spaced repetition: every drill of it
    /// ends with a result (`clean`, `helped`, `revealed`), and a clean solve moves it on to the
    /// next interval (`MistakeSchedule`). `first_result` is the result of its first drill; a
    /// mistake solved before this table existed keeps `solved`, which says nothing about first
    /// tries. `ignored` hides a mistake the person has written off, such as a slip of the finger.
    /// Keyed like `solved_mistakes`, by the game and the move, so a fresh review keeps them.
    private static let version11 = """
    CREATE TABLE mistake_reviews (
        game_key TEXT NOT NULL,
        ply INTEGER NOT NULL,
        drills INTEGER NOT NULL DEFAULT 0,
        streak INTEGER NOT NULL DEFAULT 0,
        first_result TEXT,
        last_result TEXT,
        last_at REAL,
        due_at REAL,
        ignored INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (game_key, ply)
    );
    INSERT INTO mistake_reviews (game_key, ply, drills, streak, first_result, last_result, last_at, due_at)
        SELECT game_key, ply, 1, 1, 'solved', 'solved', solved_at, solved_at + 259200 FROM solved_mistakes;
    """

    /// Searches of the first positions of reviewed games, so a game that opens like an earlier one
    /// does not search those positions again (`PositionCache`). Keyed by the engine, the budget and
    /// the exact moves from the standard start; a cached search is the search the engine would make.
    private static let version10 = """
    CREATE TABLE position_cache (
        engine TEXT NOT NULL,
        nodes INTEGER NOT NULL,
        moves TEXT NOT NULL,
        score TEXT NOT NULL,
        best_move TEXT,
        line TEXT NOT NULL DEFAULT '',
        depth INTEGER NOT NULL,
        searched_nodes INTEGER NOT NULL,
        PRIMARY KEY (engine, nodes, moves)
    ) WITHOUT ROWID;
    """

    /// Players can come from Lichess as well as Chess.com. Every existing player is a Chess.com
    /// one. A username is only unique within its site; `provider_id` keeps its column-level
    /// UNIQUE (dropping it would mean rebuilding a table four others reference), which is safe
    /// because Lichess identities are stored as `lichess:<id>`.
    ///
    /// Lichess has no monthly archives, so its download keeps two cursors instead: the newest
    /// game seen, and how far back the history has been read, until it is complete.
    private static let version9 = """
    ALTER TABLE players ADD COLUMN provider TEXT NOT NULL DEFAULT 'chesscom';
    DROP INDEX players_username;
    CREATE UNIQUE INDEX players_username ON players(provider, username);

    CREATE TABLE history_cursors (
        player_id TEXT PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
        newest_ms INTEGER,
        oldest_ms INTEGER,
        history_complete INTEGER NOT NULL DEFAULT 0
    );
    """

    /// Mistakes the person has gone back to and found a better move for, from the Mistakes tab.
    /// Keyed by the game and the move, not the analysis, so a fresh review of the game keeps them.
    private static let version8 = """
    CREATE TABLE solved_mistakes (
        game_key TEXT NOT NULL,
        ply INTEGER NOT NULL,
        solved_at REAL NOT NULL,
        PRIMARY KEY (game_key, ply)
    );
    """

    /// Hundred-game batches now run deep reviews too. Batches already waiting switch over (a game
    /// already queued for a deep review keeps that job), and the timing samples, which measured
    /// the quicker analysis, are dropped so the estimate measures deep reviews afresh.
    private static let version7 = """
    UPDATE OR IGNORE queue_items SET policy_id = 'deep-v1', checkpoint_ply = 0
        WHERE state IN ('pending', 'running') AND policy_id <> 'deep-v1'
          AND priority > 0;
    DELETE FROM queue_items WHERE state IN ('pending', 'running') AND policy_id <> 'deep-v1'
          AND priority > 0;
    DELETE FROM timing_samples;
    """

    /// Deep reviews (`DeepReview`) label each move on top of its evaluations, and record each
    /// colour's game accuracy. Standard analyses leave both empty, so nothing existing changes.
    /// Tags are a space-separated list: only the few deep-reviewed games are ever counted.
    private static let version6 = """
    ALTER TABLE analyses ADD COLUMN white_accuracy REAL;
    ALTER TABLE analyses ADD COLUMN black_accuracy REAL;

    CREATE TABLE move_labels (
        analysis_id TEXT NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
        ply INTEGER NOT NULL,
        mover INTEGER NOT NULL,
        best_move_san TEXT,
        best_line_san TEXT NOT NULL DEFAULT '',
        best_line_uci TEXT NOT NULL DEFAULT '',
        confirmed INTEGER NOT NULL DEFAULT 0,
        loss REAL NOT NULL,
        accuracy REAL NOT NULL,
        severity TEXT,
        phase TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        consequence TEXT NOT NULL,
        explanation TEXT NOT NULL DEFAULT '',
        is_best INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (analysis_id, ply)
    );
    """

    /// Policy eval-v1 stores Stockfish's evaluations and nothing derived from them, so move
    /// labels, accuracy, pattern tags and their summaries go. Each move keeps its evaluations,
    /// the engine's line after it, and the search's depth and nodes; for older reviews that line
    /// is the reply line they stored, which was the line after the move too.
    private static let version5 = """
    DROP INDEX IF EXISTS move_analyses_severity;
    DROP TABLE IF EXISTS move_tags;
    DROP TABLE IF EXISTS analysis_summaries;
    DROP TABLE IF EXISTS analysis_tag_summaries;

    CREATE TABLE move_evaluations (
        analysis_id TEXT NOT NULL REFERENCES analyses(id) ON DELETE CASCADE,
        ply INTEGER NOT NULL,
        mover INTEGER NOT NULL,
        san TEXT NOT NULL,
        uci TEXT NOT NULL,
        fen_before TEXT NOT NULL,
        score_before TEXT NOT NULL,
        score_after TEXT NOT NULL,
        line_san TEXT NOT NULL DEFAULT '',
        line_uci TEXT NOT NULL DEFAULT '',
        depth INTEGER NOT NULL DEFAULT 0,
        nodes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (analysis_id, ply)
    );
    INSERT INTO move_evaluations (analysis_id, ply, mover, san, uci, fen_before, score_before, score_after,
                                  line_san, line_uci, depth, nodes)
        SELECT analysis_id, ply, mover, san, uci, fen_before, score_before, score_after,
               reply_line_san, reply_line_uci, depth, nodes
        FROM move_analyses;
    DROP TABLE move_analyses;

    ALTER TABLE analyses DROP COLUMN white_accuracy;
    ALTER TABLE analyses DROP COLUMN black_accuracy;
    """

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
