# Implementation plan

The [specification](../chess-ios-app-spec.md) is authoritative. The [wireframes](../wireframes/index.html) define navigation/content, not production styling or a working iOS app. Product decisions are consolidated; implementation can begin without another questionnaire.

## 1. Foundation and engine spike

- Create an iOS 17+ SwiftUI project, app/test targets and CI build. Use placeholder bundle/product identifiers only in development configurations.
- Establish typed domain entities, SQLite migrations/repositories, fixtures and dependency boundaries from spec §2. No UI-level SQL or engine commands.
- Vendor/pin Stockfish 18 source, required NNUE and checksums; record all licenses. Select a GPL-compatible rules/PGN dependency after its legality and import fixture tests pass.
- Prove native in-process engine startup, UCI stop/readiness, node budgets, legal PV validation, full-history positions and serial ownership. Keep work off the main thread.
- Benchmark 100k/500k-node searches on an oldest-supported and recent physical phone. Record wall time, memory and thermal behavior. Defaults are unmeasured until this step; adjust policy/version before release if needed.

Exit: a legal PGN produces persisted, repeatable versioned per-move scores; cancellation terminates work safely. This is the first vertical slice, before polishing charts.

## 2. Public history and free-window slice

- Implement provider profile, archive index/month DTOs, serial request scheduler, conditional requests and explicit failure classification.
- Implement identity/alias verification, game-key deduplication, normalized move identity, transactions and scope membership.
- Build W01–W04, W07/W08 and W27; add first-player import, player switching, cached launch and incremental refresh.
- Derive a player's latest 1,000 across all supported classes before applying UI filters. Preserve out-of-window completed reviews.

Exit: fixtures containing 1,001 eligible games, duplicates, unsupported games and partial refreshes produce the exact expected window without losing saved data.

## 3. Single-game review

- Implement loss, per-move accuracy and game accuracy (one method for every provider, spec §5 Accuracy), confirmation searches, phases and mate/terminal handling; analyze both colors but aggregate only the selected player's moves.
- Build W09–W11 and W26. Board navigation supports actual moves, eval selection, orientation, error navigation and separate hypothetical continuation.
- Add evidence-based detectors independently, one at a time, with negative tests. An absent pattern never blocks a review.
- Checkpoint every completed ply. Replace an older complete analysis only when the new version commits successfully.

Exit: correct White/Black signs, legal alternative lines, no fabricated labels/metrics for partial or malformed games, and an interruption/resume round-trip preserves completed work.

## 4. Analytics and drill-down

- Build W05/W06 and W12/W13 using indexed queries and incremental game summaries.
- Share player/class/date/color/rated filters; preserve caller navigation/scroll context.
- Add outcome, rating, opening, accuracy and error coverage definitions exactly as spec §6. Charts need accessible summaries and data lists.
- Page Games/occurrences in batches of 50; profile a 50,000-game generated fixture without decoding all PGNs on the main thread.

Exit: independent fixture calculations match every denominator, count and rate; no-analysis is not displayed as zero.

## 5. Billing, queue and background execution

- Implement StoreKit 2 product loading, transaction verification/listening, cached valid-through entitlement, restore and system manage. Configure local StoreKit test products.
- Build W14–W17/W28 purchase handoffs. Gate new work, not saved review reading. Imports cannot grant purchases.
- Implement persistent deduplicated batches, manual-priority work, checkpoint preemption, retries and blocker sets.
- Gate iOS 26 continued-processing APIs at runtime; implement older-iOS opportunistic processing and expiration handling separately.
- Test threshold hysteresis, multiple simultaneous blockers, expiry/grace/refund/pending/offline, user system cancellation and force-quit expectations.

Exit: a multi-player batch survives process termination; expired bulk remains resumable; neither automatic recovery nor renewal overrides a user pause.

## 6. Data portability and release hardening

- Build W18–W25 and document-picker/share handoffs. Stream schema-1 export from a read snapshot; import to staging and validate before atomic merge.
- Add scoped deletion with reference protection, backup-first links and clear result states.
- Complete accessibility, landscape, dark mode, long usernames and large text on every route; test board and graph VoiceOver navigation.
- Supply real source/support/privacy/terms URLs, license texts, corresponding-source release, configured Apple products and release terms review.

Exit: acceptance suite passes, physical-device numbers are recorded, StoreKit sandbox purchase lifecycle passes, and release checks are signed off. Wireframe browser checks do not substitute for these.

## Fixture and verification matrix

| Area | Required cases |
|---|---|
| Rules/PGN | Castling through check rejected; legal castling; en passant; promotion/underpromotion; SetUp/FEN; repetition; 50/75-move context; comments/variations; malformed SAN; zero plies; short completed games |
| Scoring | White/Black symmetry; threshold boundaries 4.999/5/10/20; cp extremes; best-root equality; confirmation root change; mate-to-mate; losing mate; terminal draw; result code independent of engine eval |
| Patterns | Proven allowed/missed fork; absolute pin that actually matters; defended/undefended capture; compensated sacrifice; unresolved PV; slower mate; mate missed by actual opponent; no motif with valid severity |
| Provider | 404 profile vs unavailable month; empty archives; renamed same/different ID; absent provider ID; UUID/URL fallback; changed PGN; cache headers; 429; Retry-After; offline; repeated 5xx; truncated month |
| Window | 999/1,000/1,001; equal completion timestamps; shared players; all four classes; filters after selection; short/zero-move included; variants excluded; saved older review; premium downgrade; import without verified window |
| Aggregation | Unknown result; missing opening; rated-only rating; both player colors; failed/partial/old-policy exclusion; zero analyzed moves; overlapping tags; phase denominators; daily accuracy bucket sample count |
| Queue | Kill at every checkpoint; engine watchdog; malformed game continues batch; manual preemption; duplicate jobs; FIFO players/newest games; cancel; retry failed; multiple blockers; resumed entitlement plus manual pause |
| Purchases | Success; cancellation; pending; unavailable product; verification failure; active; grace; billing retry without grace; expiry; refund/revoke; restore; offline before/after valid-through; unknown entitlement |
| Backup | Round-trip; merge duplicates/conflicts; different policy; bad checksum; unsupported schema; unsafe path/symlink; expansion bomb; oversized record/nesting; invalid foreign key; cancellation/low disk before commit; shared references |
| Device/UI | iOS 17 fallback; iOS 26 availability/rejection/expiration; oldest and recent phone; heat/battery/charging/Low Power Mode; 50k games; offline launch; 44pt targets; VoiceOver; large text; landscape |

## Measured targets and evidence

Start with a responsive main thread (no sync engine/database/import work), paged lists, bounded engine memory and successful recovery under injected failures. Establish numerical launch, scrolling, memory, storage and per-game timing baselines from physical devices in milestone 1; track regressions against those baselines. Do not market an unmeasured completion duration.

Store unit/integration results, device/OS/build details, engine/net/policy IDs and benchmark fixture hashes with release evidence. This documentation package contains no claim that native app tests or Apple distribution review have been completed.
