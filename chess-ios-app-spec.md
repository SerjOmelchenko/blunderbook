# Chess Games Analyser — iOS development specification

Version 1.0 · 16 September 2026 · Ready for implementation

This document consolidates agreed product behavior and selects technical defaults for implementation. Performance figures are targets to validate, not measured claims. Publication dependencies are separate from development work (§14).

Companions: [screen/state inventory](docs/screens.md), [interactive wireframes](wireframes/index.html), [development plan and acceptance checks](docs/development-plan.md). Screen IDs match across deliverables. Wireframe players, statistics, prices and engine evaluations are illustrative.

## 1. Product scope

An iPhone app that downloads any public Chess.com player's completed games, analyzes them locally using Stockfish, and shows mistakes with supporting board continuations. Three tabs: **Analytics, Games, Mistakes**. Player selection and Settings are shared destinations.

- Anyone can track any public player. No ownership verification, Chess.com login, app account, or Sign in with Apple. No artificial tracked-player count limit in v1; each player has a separate free window.
- Standard chess only: bullet, blitz, rapid, Daily. Include rated/unrated completed games regardless of length or recorded ending. A three-move game counts and is analyzed normally. Never infer disconnection, intent or psychological cause.
- Exclude ongoing games, variants, Puzzle Rush and data unavailable from the public API. Chess960 exclusion is a product choice, not a Stockfish limitation.
- On-device computation and storage, resumable queues, retained reviews and manual backup. No automatic cross-device sync or custom backend.
- Four mistake fields: severity, phase, optional pattern, supported consequence. Show mistakes and better continuations directly. No retry, puzzles, playing against the engine, LLM/chat, or “Brilliant” labels.
- One standard quality profile. No Quick/Deep setting or claim of exact Chess.com/Lichess score equivalence, player-strength prediction or cheat detection.
- Entire combined application under GPLv3, including UI, engine wrapper and tagging logic. Subscription rules are in §3; release considerations in §14.

## 2. Platform and architecture

| Area | Selected implementation baseline |
|---|---|
| Platform | iPhone, iOS 17.0+. iOS 26 background features are availability-gated. Adaptive centered iPad layout; no dedicated tablet workspace in v1. |
| UI | SwiftUI, NavigationStack, native sheets, Swift Charts; portrait/landscape, Dynamic Type, VoiceOver, light/dark, Reduce Motion. |
| Persistence | System SQLite via sqlite3 behind typed repositories; WAL, foreign keys, transactional migrations and indexed/paged queries. No CloudKit. |
| Networking | URLSession, one serial provider scheduler, conditional requests, cancellation and retry/backoff. |
| Engine | Stockfish 18 tag `sf_18`; lock exact source commit and required NNUE checksums in the build manifest. Native C++ with Objective-C++/Swift bridge; no child process. |
| Concurrency | Single engine worker off the main thread; actors/serialized boundaries for engine, repository and queue ownership. |
| Payments | StoreKit 2 verified transactions and entitlement updates; no account/entitlement backend. |
| Backup | Versioned ZIP with JSON manifest and streamed NDJSON records; no executable content. |

Module boundaries: `AppUI → UseCases → repositories + EntitlementService`. `ArchiveSync` owns provider requests; `ChessRules` owns PGN/FEN/legal moves; `EngineBridge` owns UCI lifecycle; `AnalysisPipeline` owns scoring/detectors; `AnalysisCoordinator` owns durable queues; `BackupService` owns import/export. UI never sends engine commands or queries tables directly.

Use a tested GPL-compatible chess-rules implementation supporting castling, en passant, promotion, repetition, move counters and PGN starting-position tags. Selection belongs to the initial engine spike, with license/fixtures checked before adoption. Do not copy AGPL Lichess puzzle-tagger code into this GPLv3 app without resolving licensing; implement detector logic independently from the reference descriptions. The chosen UI stack does not require copying Lichess code.

## 3. Plans and eligibility

| Capability | Free | Active subscription |
|---|---|---|
| Tracked public players | Multiple | Multiple |
| New individual analysis / reanalysis | Latest 1,000 eligible completed games per player | All available eligible completed games |
| Analyze all games | Opens plan screen | Available, no game-count cap |
| Aggregate statistics | Current 1,000-game window, then filters | Full downloaded eligible history, then filters |
| View saved reviews, including older games | Yes | Yes |
| Export/import | Yes | Yes |

One monthly auto-renewing product, target US price approximately $5/month, no introductory trial in v1, Family Sharing disabled. Production UI uses StoreKit's localized price/period. Select the available price point during product setup; do not hard-code `$5`.

Window: deduplicate eligible games, order by `(endTime DESC, gameKey DESC)`, take 1,000 **across all four time classes combined** for each player. Apply date/class/color/rated/opening filters afterward; filters cannot expand eligibility or create a separate allowance. Unsupported games do not consume slots. Short and zero-move completed games do.

When game 1,001 arrives, game 1 leaves free aggregates and new/reanalysis eligibility. Keep its data and review. Games has **Eligible games / Saved reviews** segments; older saved reviews carry “Outside your free window.” Opening them never changes aggregate scope. One Apple purchase unlocks all locally tracked players, not a particular Chess.com account.

When entitlement expires, pause bulk at the next safe stop/checkpoint, retain results and pending work, recalculate free aggregate scope. Renewal removes the entitlement pause; continuation requires no manual pause and no other blocking reason. Individual reviews remain allowed in the free window. Restoring purchases restores premium access, not profiles, games, reviews or queue progress.

Read verified current entitlements at launch and listen for updates. Subscribed and verified grace-period access are premium. Expired/revoked/refunded access is free; billing retry alone is not premium. Offline, honor a previously verified entitlement only through its known valid-through date. Unknown status shows “Checking subscription,” preserves all saved reviews and pauses purchase-dependent work. Pending purchase stays pending; user dismissal is not an error. Offer Restore Purchases, system Manage Subscription, privacy and terms. Backups cannot grant entitlements.

## 4. Identity, provider access and refresh

Player identity: local UUID plus provider `player_id` when available; current username and verified aliases. Trim username input, reject empty/control/path input, percent-encode paths, match case-insensitively but retain display casing. Never request a password.

The provider has username-addressed profiles and monthly archives, not a guaranteed ID-to-new-name lookup. Merge an alias only when fetched IDs match. If an old username stops resolving, retain data and offer Update username (W27). Verify the new name resolves to the same ID; a different ID must not merge. If ID is absent, use a provisional local identity and do not merge by username alone. [API reference](https://www.chess.com/news/view/published-data-api).

### Refresh contract

1. Show cached data immediately. Refresh on app foreground/open and pull-to-refresh; coalesce duplicate refreshes. Selected player first, then other profiles serially. Respect provider cache expiry and make no promise of immediate game availability.
2. Fetch profile/index, then month payloads newest first. Free initial import stops when the complete latest-1,000 window is known or available months are exhausted. Paid import continues to full history incrementally. Whole-month responses can contain older rows; eligibility is filtered locally.
3. Reuse stored months; revalidate newly listed/current months first and other cached months as validators expire. Track per-month completeness. Conditional requests avoid downloading unchanged archives.
4. Upsert games by provider UUID if returned, otherwise canonical game URL. Store a normalized starting-position+move-sequence hash; content changes invalidate matching analysis. Repeated imports never duplicate a game. Partial requests never purge cached records.
5. Publish new free-window membership atomically after a successful bounded refresh. Do not evict old-window results during an incomplete download. Show Loading history / History incomplete as appropriate, Last checked per player, and an API-cache caveat. A failed/partial refresh does not advance the successful timestamp.

Use a descriptive User-Agent, serial requests, `ETag`/`Last-Modified`, `Cache-Control` and `Retry-After`. On 429, pause requests and show the rate-limit state. Retry network/5xx failures with jittered 2, 4, 8, 16, 32-second backoff, then stop that refresh. Manual Retry begins a new attempt. [Provider response guidance](https://support.chess.com/en/articles/9650547-what-is-the-pubapi-and-how-do-i-use-it).

Distinguish player-not-found, unavailable archive, no eligible games, offline, rate limit and malformed PGN. Do not interpret a 404 as proof of privacy restrictions or prescribe an unverified privacy setting. Retain eligible malformed-game metadata, count the game, show analysis failure and allow retry after refresh. Zero-move games count but have no invented accuracy/mistakes.

Completion requires an archived game with end timestamp and result. Preserve raw result codes; normalize W/D/L from the player's recorded result. Unknown/inconsistent outcomes remain in game totals, appear as Unknown and are excluded from outcome percentages with a stated denominator. A resignation/timeout result is never substituted for an engine evaluation.

## 5. Analysis policy: standard-v2

### Engine execution

- Stockfish 18 + pinned NNUE, Threads=1, Hash=64 MiB per engine, MultiPV=1, full strength, ponder off, Chess960 off. Bundle nets for offline use. No downloaded engine code or evaluation service.
- Supply full legal game history, preserving repetition and halfmove counters. Reset hash and histories before every root search, so each search depends only on its position, history and budget, and a game's result is identical on any engine instance. Analyze a game as one unit: every position, then the confirmations; publish nothing before it completes.
- Evaluate before each move for the best line and after the recorded move for the opponent's best response. **100,000 nodes per root search**. Store achieved depth/nodes, best root move and up to 12 legal PV plies. Normalize stored scores to White; convert to mover perspective for scoring.
- If played move equals the best root move, assign zero loss and reuse its line; independent-search variation must not manufacture a mistake. If initial loss reaches 5 points, a mate appears/disappears, or after-eval improves by >5 points, confirm both roots at **500,000 nodes each**; a position shared by two confirmed plies is searched once. Use that pair for the final classification. Tested and not adopted: keeping one game's hash and searching its positions last-first matched these labels and game accuracy at 100,000/350,000 nodes (17% fewer) against 4M-node searches of 48 real games, and lost measurably below about 70% of the nodes.
- Use exact terminal scores for legal checkmate/stalemate/automatic draw; otherwise preserve engine mate distances. Never represent a win on time as checkmate. Keep pre-move and best-response lines separate from the actual game.
- Stop on cancellation or interruption; an interrupted game is analyzed again from its first move. Never score a partial search. A 30-second engine-response watchdog (three minutes for efficiency-core searches, which the system may starve while the phone is busy) stops the search and restarts the game once; repeated failure marks the game failed and continues other work. Benchmark before release; budget or order changes require a new policy ID.
- Analyze both colors for review. Player analytics use only that player's moves. Save a game's review when it completes; publish nothing before. Zero moves yields No moves to analyze. Do not skip book/forced moves or exclude short games.

### Severity and accuracy

From mover-perspective centipawns `cp`, use `W(cp) = 100 / (1 + exp(-0.00368208 × cp))`; bound cp to ±10,000 for numeric safety. This is a fixed evaluation-derived index, not a personalized probability. Winning mate maps to 100, losing mate to 0, drawn terminal position to 50. Original mate scores are retained for display.

`loss = max(0, W_before − W_after)` in percentage points:

| Loss | Label |
|---|---|
| <5 | No mistake label |
| >=5 and <10 | Inaccuracy |
| >=10 and <20 | Mistake |
| >=20 | Blunder |

These are app v1 thresholds. Best may annotate the root move the engine chose; a near-equal alternative is not necessarily Best. No Excellent/Good/Brilliant taxonomy in v1.

Move accuracy is 100 for zero loss, otherwise `clamp(103.1668 × exp(-0.04354 × loss) − 3.1669, 0, 100)`. A color's game accuracy is the **arithmetic mean** of its move accuracies, displayed to one decimal; unavailable with zero moves. This is explicitly this app's aggregation, not Lichess's weighted/harmonic game score. Trends average completed game values within daily buckets and show sample counts. [Published formula reference](https://lichess.org/page/accuracy).

Do not mix provider accuracy into app metrics. Persist engine, net, policy, scoring and tagger versions. After a policy change, keep historical saved reviews; current aggregates include only matching policy results, with excluded-old-version coverage and a reanalysis action. Replacement is atomic only after new analysis succeeds. Preserve the previous review on failure. Explain that already-decided positions can yield high accuracy.

### Four fields

| Field | Definition |
|---|---|
| Severity | One threshold label above; absent for non-errors. |
| Phase | Before the played move: endgame when remaining material weights across both sides total <=8 (minor=1, rook=2, queen=4; exclude pawns/kings); otherwise opening in first 20 plies, then middlegame. Endgame remains endgame after promotion. |
| Pattern | Zero or more supported tags with evidence plies/squares. No inference about player thoughts. |
| Consequence | Supported material loss/missed gain, allows mate/misses forced mate, lost winning advantage; otherwise generic evaluation loss. |

Initial detector scope:

- **Undefended piece:** opponent best line legally captures an undefended non-pawn piece and material remains down after forcing captures resolve. Exclude compensating sequences/sound sacrifices; omit when ambiguous.
- **Allowed / missed fork:** a relevant continuation attacks two or more non-pawn opponent pieces (king included) and demonstrates material gain or mate. Geometry alone is insufficient. Allowed uses the response after the played move; missed uses the unplayed best line.
- **Allowed absolute pin:** a slider pins a piece to its king and the continuation demonstrates consequent loss/mate. General relative-pin interpretation is out of scope.
- **Allowed mate / missed forced mate:** confirmed roots establish new losing mate, or lost availability of winning mate. Choosing a slower still-forced mate is not a miss. A missed mate may be a detail tag without error severity when winning chances are preserved; count it as an error only if severity qualifies.
- **Material consequence:** pawn=1, knight/bishop=3, rook=5, queen=9. Follow forcing checks/captures/promotions to a quiet endpoint within 12 plies. If the line does not resolve or compensation is unclear, omit the specific material claim.
- **Lost winning advantage:** confirmed W_before>=80 and W_after<60 when no more specific proven consequence exists. Other errors say Reduces the position evaluation.

Templates state what the line demonstrates, e.g. “After …Qh4, Black delivers checkmate.” Always allow inspection of the supporting continuation. An opportunity still counts if the actual opponent missed it. A motif must explain the deterioration/missed alternative, not simply occur elsewhere on the board. If unclassified, show evaluation and line without fabricating a tactical cause. Detectors require positive and negative regression fixtures.

## 6. Analytics

- Shared context: selected player, one time class, date range, color and rated filters, plan scope. Default Rapid, all dates/colors, rated+unrated. Preserve selection; if no Rapid games select most-played live class, then Daily. No combined rating series; Daily is always separate.
- Game totals/outcomes/openings use eligible metadata within plan scope. Ratings use rated games only, ordered by completion time. A profile's current rating may be separate but must not be inserted into a filtered historical chart without a matching date.
- Group openings by PGN ECO/provider opening metadata; missing metadata is Unknown opening. Sort by count then name. Do not guess an opening from an arbitrary URL slug. Opening detail drills into matching games.
- Accuracy/error metrics use fully completed current-policy analyses. Show coverage for the **same** player/filter/scope: e.g. 83 of 1,000 analyzed, with failed/incomplete/older-policy counts when applicable. No analysis means empty charts, not zero accuracy.
- **Errors** means inaccuracies + mistakes + blunders; count a move once. **Mistake** severity is one subset. Labels must make the distinction clear.
- Rate = `100 × qualifying error moves / analyzed moves by the tracked player`, over the selected sample. Never average per-game rates. Count a tag once per move per category; overlapping category totals may exceed unique errors and must be labeled. Phase denominators contain only player moves in that phase.
- Unknown pattern is a valid category. Unknown outcomes are omitted only from W/D/L percentages; zero-move games only from accuracy/move denominators; incomplete/failed analyses only from computed metrics. All remain in game/coverage totals. No short-game exclusion or termination-based score adjustment.

## 7. Queue and device behavior

One performance-core engine handles manual reviews, and bulk while the phone is cool; up to one engine per efficiency core (at most four) handles bulk side by side. Each engine takes one game at a time, claimed atomically so no game runs twice. A bulk batch covers the selected player's eligible history known at start and historical games discovered during that initial download. It does not automatically analyze future new games after completion. Deduplicate `(gameKey, policyID)` jobs; skip matching completed analyses. Multiple players' batches are FIFO, each newest-game-first; a manual review stops any bulk game on the performance-core engine, which returns to pending.

Item states: pending → running → completed/failed. Interrupted item returns to pending and restarts from its first move. Queue blockers are a **set**: user, thermal, battery, lowPower, entitlement, storage, system. Processing requires all applicable blockers cleared; one clearing cannot override another. Highest-priority reason is displayed with other reasons discoverable.

| Event | Behavior |
|---|---|
| Pause | Persist progress; only explicit Resume clears user pause. |
| Cancel | Confirm, remove pending batch items, keep completed reviews. A new batch skips completed work. |
| Manual review | Stop the performance-core engine's bulk game, analyze the selected game there, then return if unblocked. |
| Fair thermal | Performance-core engine stops taking bulk; efficiency-core engines continue. |
| Serious/critical thermal | Pause all engine work. Resume eligible bulk after nominal/fair state remains stable for 60 seconds. Each such episode while analyzing removes one efficiency-core engine (minimum one); one returns after 20 unbroken nominal minutes. |
| Battery <=20%, unplugged | Pause bulk. Recover at >=30% or charging. Unknown battery level is not invented. |
| Low Power Mode | Pause bulk until disabled. Foreground individual reviews allowed unless thermally blocked. |
| Entitlement expiry | Pause bulk; preserve results and queue (§3). |
| Free disk <500 MiB | Pause downloads/analysis/import; link to storage. Resume at >=750 MiB. No silent deletion. |
| Engine/PGN failure | Engine retry once; record failed item and continue. Provide Retry failed. |
| App/OS interruption | Stop engines; their games return to pending. Resume on next granted execution unless manually paused. |

iOS 26+: `BGContinuedProcessingTask` for user-started work, real progress, rejection/expiration handling. System user cancellation becomes user pause, not immediate rescheduling. iOS 17–25: foreground plus opportunistic `BGProcessingTask`; external power requested for background bulk, network only if downloads remain. Complete tasks once and persist before expiration. Do not promise runtime or automatic restart after force-quit. [Apple background guidance](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados).

Show completed/known total, current game, failures and blockers. ETA is **active processing time**, not calendar time. First use shows Estimating while sampling up to three games; then median seconds/analyzed ply × estimated remaining plies, expressed as a range. Mark provisional until history finishes downloading. Device timing samples are not imported from backup. No hard-coded “weeks” promise.

## 8. Navigation and screens

First launch with no player opens Welcome. Otherwise restore selected player/tab and cached content. No required paywall, notifications prompt or tracking prompt before import. Settings and player picker are reachable from every root tab. Review returns to the originating list/filter/scroll. Board orients to tracked player with Flip available.

| ID | Screen | Primary actions |
|---|---|---|
| W01 | Welcome | Add player; import backup |
| W02 | Add player | Resolve username; confirm profile; start import |
| W03 | Importing history | Open available games; retry; leave without losing downloaded rows |
| W04 | Tracked players | Switch; add; update username; remove |
| W05 | Analytics | Class/filter; openings; games; queue; settings |
| W06 | Opening detail | Matching games and reviews |
| W07 | Games | Eligible / Saved reviews; filter; review; analyze all; queue |
| W08 | Filters | Class/date/color/rated/status; apply/reset/cancel |
| W09 | Game review | Select move/graph; next/previous error; flip; continuation |
| W10 | Continuation | Actual / Better line; step ply; return |
| W11 | Individual analysis | Progress; stop; completed review; retry |
| W12 | Mistakes | Severity/phase/pattern; count/rate; category |
| W13 | Mistake category | Occurrences; exact game/ply |
| W14 | Bulk preparation | Estimate; start; dismiss; upgrade |
| W15 | Queue | Pause/resume/cancel; retry failed; completed reviews |
| W16 | Premium plan | Subscribe; restore; legal links; dismiss |
| W17 | Subscription | System manage; restore; renew |
| W18 | Settings | Players; plan; backup; storage; about |
| W19 | Backup & restore | Export; system import picker |
| W20 | Export | Progress; cancel; system share/save; result |
| W21 | Import preview | Counts/conflicts; import; choose another; cancel |
| W22 | Import result | Summary; players; retry |
| W23 | Storage & data | Per-player usage; clear analysis/remove player/clear all; backup |
| W24 | Confirmation | Action-specific impact; confirm/cancel |
| W25 | About & licenses | Build; source; license text; privacy; terms |
| W26 | How analysis works | Formula explanation; limitations; versions |
| W27 | Update username | Resolve; ID check; relink/mismatch |
| W28 | System handoff | Document native purchase/manage/share/file-picker behavior |

[Screen inventory](docs/screens.md) defines all required states and transitions. Native handoffs are explanatory wireframes, not replicas of Apple's UI. Root filters are shared across Analytics/Games/Mistakes; list-specific review status remains local. Saved reviews can include older games but always carry that scope label.

## 9. Data model and performance

| Entity | Essential keys/fields |
|---|---|
| Player | Local UUID, provider ID nullable unique, username/aliases, tracked flag, last check/status |
| Archive | Player+month unique, URL/validators/cache expiry, fetch completeness |
| Game | Canonical key, URL/UUID, PGN/start FEN/move hash, completion UTC, class/control/rules/rated, both players/rating/result, ECO, parse state |
| PlayerGame | Player+game unique, color, window version/membership; shared games do not duplicate engine work |
| Analysis | Game+policy active result, engine/net/scoring/tagger versions, status/next ply, summary/timestamps; retain prior review during replacement |
| MoveAnalysis | Analysis+ply, mover/SAN/UCI, before/after White score or mate, best move/PVs, depth/nodes, loss/accuracy, severity/phase, evidence tags |
| QueueBatch/Item | Batch player/created/state/blockers; game+policy unique active job, priority/checkpoint/attempt/error |
| Preferences | Selected player/tab/filters, schema version, system appearance |

Index end time, player-game membership, analysis completion/policy, severity/phase/pattern and queue priority/state. Page lists in 50-row batches. Store incremental per-game/category summaries; never load 50,000 PGNs or scan all move arrays on the main thread. Test derived totals against original rows through migrations.

Persist user database under Application Support, not purgeable caches. Retain games/reviews until explicit deletion. HTTP caches/temporary exports/logs are disposable. Include database in normal OS device backup, exclude bundled engine/nets/temp files. Do not promise OS backup availability; app deletion may remove data and manual export is the controlled recovery route.

## 10. Backup, import and deletion

Export `.chessbackup` ZIP: `manifest.json` (schema=1, build, UTC, counts/checksums), `players.ndjson`, `games.ndjson`, `player-games.ndjson`, `analyses.ndjson`, `moves.ndjson`. Include downloaded PGNs and **completed** analysis, not queue/StoreKit/credentials/diagnostics/engine assets. Export from consistent read snapshot, stream to file, then native save/share. No automatic upload.

Import to staging; validate schema, paths, counts, checksums, references and data types before mutation. Reject path traversal/symlinks, encrypted archives, unsupported schema, records >10 MiB, excess nesting and expansion >20 GiB. Enforce limits against actual streamed bytes; verify space. Independently validate PGN and recompute eligibility; never trust backup entitlement/window flags.

Merge players by provider ID and games by canonical key. Provisional identities do not merge without verification. Skip duplicates; keep existing complete analysis for same game+policy on conflict. Different-policy results are retained as historical reviews; only current-policy results enter metrics. Preview new/duplicate/conflict counts, then atomic commit. Cancel/error leaves original data untouched. Existing out-of-window review visibility applies to imported results. Offline import shows last-known/unverified scope until refresh; it cannot claim verified current-window membership. For a newly imported player without a locally verified provider window, saved reviews are readable but new free analysis and free aggregate statistics wait for a successful bounded refresh. An existing verified local window is not replaced by backup claims.

Clear analysis confirms deletion of relevant reviews/checkpoints, keeps games. Remove player confirms local profile/associations/queue removal; delete shared records only if no remaining tracked player references them. Clear all cancels work and deletes local profiles/games/reviews; it does not cancel Apple's subscription or delete exported files. Offer Backup first, name exact scope, show completion, route to Welcome if no player remains.

## 11. Accessibility, privacy and errors

Minimum 44×44 pt targets; Dynamic Type; labeled toolbar/tab controls; severity/outcome conveyed by text as well as color. Accessible square/piece and move descriptions, chart summaries/data lists, tracked-player orientation, Reduce Motion. Long usernames fit accessibly. Sheets have clear cancel/close routes; keep underlying filter/scroll state. No errors detected is distinct from no completed analyses.

Failures preserve context and data: provider failure is not a paywall; low storage is not permission to delete; failed game does not stop a batch; purchase failure does not remove reviews; invalid import fails before commit. Logs are local and avoid full PGNs/profile details by default. No third-party tracking or analytics SDK. Privacy copy explains direct public-provider requests and Apple purchases, and that exports contain player/game data.

Wireframes use restrained monochrome structure and one accent; final branding remains separate. All example figures are explicitly labeled illustrative outside the phone viewport.

## 12. Acceptance criteria

1. With 1,001 eligible games, free scope is latest 1,000 before filters. Oldest saved review remains viewable but excluded from metrics and free reanalysis.
2. Shared games are analyzed once; per-player colors/denominators differ correctly. Matching ID renames preserve history; mismatches never merge.
3. Short/timeout/abandoned games count and score normally. Zero-move game counts with unavailable accuracy. Bad PGN is visible without fabricated metrics.
4. White/Black sign tests are symmetric; exact best move gets zero loss; mate-to-mate is not a missed mate; recorded result does not replace evaluation.
5. Termination loses at most the games in progress, which restart; completed games are kept; unfinished game never publishes final metrics. Multiple pause reasons compose correctly.
6. Free bulk is unavailable. Expiry/pending/cancellation/grace/refund/offline/restore follow §3; no imported data grants access.
7. Backup round-trip retains source and all completed results/provenance. Invalid/canceled import leaves existing database unchanged.
8. Offline cache loads without network. Provider errors retain data/timestamps. Unsupported/ongoing games never enter engine work.
9. 50,000-game fixture uses paged lists and incremental summaries. Record measured timing/memory/storage/thermals on an oldest-supported and a recent physical phone before release.
10. Every inventory route/state has an implemented destination or native handoff; VoiceOver, large text and landscape remain usable.

## 13. Development defaults and calibration

The defaults in §§2/5/7/10 resolve previous open technical questions: iOS 17/SwiftUI/SQLite; Stockfish 18; node-limited standard-v2; severity cutoffs 5/10/20; arithmetic game accuracy; rules/templates; battery cutoff/recovery 20/30%; storage 500/750 MiB; merge-only schema-1 backups. Fixtures/device measurements may justify tuning **before release**, with policy/version changes whenever output changes. No silent new tier or cloud dependency.

Implementation milestones and tests are in [development-plan.md](docs/development-plan.md). Initial engine integration, chess-rules dependency selection, and mobile performance measurements are implementation tasks, not additional product questionnaires.

## 14. Publication dependencies — not development blockers

- Set real Apple bundle/product IDs, monthly regional pricing, Family Sharing off and agreements. These account-owned values cannot be invented in a spec. Production StoreKit UI requires the configured product.
- Publish corresponding source, build instructions/assets and notices for each shipped binary. Maintain dependency/asset license inventory. GPL allows paid distribution; recipients may modify and redistribute, including removing local payment checks. [Stockfish license](https://github.com/official-stockfish/Stockfish/blob/master/Copying.txt).
- Lichess is a practical distribution reference, not a legal exception for this app. Review App Store/GPL compatibility for release; a source link alone does not establish it. [Lichess mobile](https://github.com/lichess-org/mobile), [Apple minimum license terms](https://www.apple.com/legal/internet-services/itunes/dev/minterms/).
- Working title: Chess Games Analyser. Original branding/assets; no Chess.com logo/name in the title. Descriptive provider copy and unaffiliated disclaimer need final terms/branding review; a disclaimer is not permission. [Chess.com agreement](https://www.chess.com/legal/user-agreement).
- Supply real source/privacy/terms/support URLs, notices and app-privacy disclosures. Complete physical-device benchmarks, StoreKit sandbox tests, accessibility checks and source-release audit. This specification does not claim those have passed.

Technical references: [Stockfish 18 release](https://github.com/official-stockfish/Stockfish/releases/tag/sf_18), [StoreKit entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements), [thermal states](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).
