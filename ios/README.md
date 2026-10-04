# Chess Analyser — iOS app (v1)

A working implementation of the [development specification](../chess-ios-app-spec.md): an iPhone app
that downloads any public Chess.com player's completed games, analyses them on the device with
Stockfish 18, and shows each mistake together with the line that demonstrates it.

Nothing in the repository root was modified; this folder is self-contained.

**Licence: GPLv3.** The app links Stockfish, so the whole application is GPLv3 — see
[LICENSE](LICENSE), [NOTICE.md](NOTICE.md) and the release checklist at the end of this file.

## Build and run

```sh
open ios/ChessAnalyser.xcodeproj
```

Select the **ChessAnalyser** scheme and an iPhone simulator (or your device), then run. Requires
Xcode 16 or newer; it was built and tested with Xcode 27 against the iOS 27 SDK, with a deployment
target of iOS 17.0.

There are no package dependencies and no CocoaPods. Stockfish is vendored as source under
`Vendor/Stockfish/` and compiled by the app target; its two NNUE networks are checked in under
`ChessAnalyser/Resources/Networks/` and bundled for offline use. That's **~112 MB of the repo and
of the app download** — see "Size" below.

The bundle identifier is `com.example.chessanalyser` and the team is `78873P6WBY`. To build
under a different account, change both under *Signing & Capabilities*.

Tests:

```sh
xcodebuild test -project ios/ChessAnalyser.xcodeproj -scheme ChessAnalyser \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

115 tests, about 100 seconds. Most are instant; the analysis tests drive real Stockfish at the
real 100k/500k node budgets, on more than one engine, which is the point of them.

### Trying it without waiting for a download

```sh
xcrun simctl launch booted com.example.chessanalyser -seed-demo
```

`-seed-demo` loads ten real games for a fictional `demoplayer` and queues five of them for
analysis. It is `#if DEBUG` only and does nothing without the argument. `-start-tab games`,
`-open-game demo-0`, `-open-route queue` and `-open-sheet paywall` jump straight to a screen.

For the ordinary path, just run the app and add a real Chess.com username.

## What works end to end

Add a player → their monthly archives download → games appear → analyse one game or queue them all →
a saved review with an evaluation graph, per-move severities, evidence lines and a steppable
continuation → aggregate statistics and mistake categories → export and re-import everything.

| Area | State |
|---|---|
| Chess rules | Complete. Passes perft to depth 5 on six standard positions, full SAN in and out, PGN with comments, variations, NAGs and `SetUp`/`FEN`. |
| Engine | Stockfish 18, vendored and compiled in-process. The only source of analysis. |
| Analysis policy | `standard-v1` exactly as specified: 100k nodes per root, 500k confirmation pair, 5/10/20 severity cut-offs, arithmetic-mean game accuracy. |
| Detectors | Undefended piece, allowed and missed fork, allowed absolute pin, allowed mate, missed forced mate, material consequence, lost winning advantage. Every tag is backed by a line that resolves. |
| Persistence | SQLite via `sqlite3` behind typed repositories, WAL, foreign keys, versioned transactional migrations, 50-row paging, per-game summary tables. |
| Provider | Chess.com Published-Data API with conditional requests, `Retry-After`, jittered backoff, and classified failures. |
| Free plan | Analyse any single game, free and unlimited. "Analyse all games" is Premium. 3 tracked players. Every plan downloads and shows the whole history. |
| Queue | Durable, deduplicated, per-ply checkpoints, manual preemption, composing blocker set (user, thermal, battery, Low Power Mode, entitlement, storage). |
| Billing | StoreKit 2 against the real product `monthly_premium` (group "Premium Subscription", 1 month, Family Sharing off). Verified entitlements, updates listener, restore, cached valid-through for offline. Premium unlocks bulk analysis and unlimited players. |
| Backup | Versioned `.chessbackup` (stored ZIP + manifest + NDJSON), staged validation before any write, merge-only atomic commit. |
| UI | All 28 screens from the inventory, light and dark, Dynamic Type, VoiceOver labels, chart data alternatives, 44pt targets. |

## The engine

**Stockfish 18** (tag `sf_18`, commit `cb3d4ee9b47d`), vendored as source and compiled into the app
by the app target. There is no child process: the bridge drives `Stockfish::Engine` directly
through its C++ API, which is what §2 asks for.

| | |
|---|---|
| Search | `go nodes N` — 100,000 per root, 500,000 for a confirmation pair (policy `standard-v2`) |
| Settings | Threads 1, Hash 64 MiB per engine, MultiPV 1, full strength, no ponder, Chess960 off |
| Engines | One on a performance core, plus one per efficiency core (up to four; fewer below 6 GB of memory), sharing one copy of the networks |
| Networks | `nn-c288c895ea92` (big, 104 MB) and `nn-37f18f62d772` (small, 3 MB), bundled |
| Speed | 1.1–1.4M nodes/s on an iPhone 16 Pro performance core, 250–300k per efficiency core, measured |

Two details in `StockfishBridge.mm` matter more than they look:

- **The hash is cleared before every root search.** Without it, results depend on what was
  searched before. §5 asks for independent roots; this is what makes the app's numbers
  reproducible, and what lets any of several engines analyse any game with the same result.
  Keeping one game's hash and searching its positions last-first was tested against 4M-node
  searches of 48 real games: it matched at 17% fewer nodes and lost measurably below 70%, too
  little to replace every saved review with a new policy. `AnalysisPolicy.keepsEngineMemory`
  switches it on.
- **Positions are sent as a start FEN plus the full move list**, never a bare FEN, so the engine
  sees repetitions and the halfmove clock (§5: "FEN alone is not an adequate cache key").

**Stockfish is the only source of analysis.** There is no second engine and no fallback. If the
networks cannot be loaded, the app says analysis is unavailable, leaves saved reviews readable, and
keeps queued work — it does not substitute a weaker engine whose results would land in the same
policy's statistics and quietly become incomparable.

`ChessEngine` remains the seam a different engine would be dropped into, and `GameAnalyzer` depends
on the protocol rather than the implementation, but only `StockfishEngine` implements it.

Changing engine changes output, so the policy identifier is **`standard-v2`**. Reviews saved under
`standard-v1` stay readable and drop out of current aggregates until reanalysed, exactly as §5
requires.

## The free plan

| | Free | Premium |
|---|---|---|
| Analyse a game you open | Yes, unlimited | Yes |
| Analyse all games at once | — | Yes |
| Tracked players | 3 | Unlimited |
| History downloaded and shown | All of it | All of it |
| Saved reviews | Kept for good | Same |

There are no credits or counters. Premium gates *starting* a bulk run; work already queued
finishes even if the subscription lapses meanwhile, and saved reviews are always readable.
Earlier builds charged per-player credits; their queue rows still decode, and the old
`player_allowances` table is simply no longer read.

## Subscription

Wired to the product configured in App Store Connect:

| | |
|---|---|
| Product ID | `monthly_premium` |
| Group | Premium Subscription |
| Duration | 1 month |
| Family Sharing | Off, as §3 requires |
| Price | Read from StoreKit at runtime — never hard-coded |

`Supporting/Products.storekit` mirrors it for local testing and is referenced by the scheme, so
running from Xcode gives a working sandbox purchase. It is also bundled with the test target,
which lets `SubscriptionTests` drive a real `SKTestSession`: the product loads, purchase flips the
entitlement to premium, a cancelled purchase grants nothing, and a
cleared transaction falls back to free.

Revocation and refund cannot be produced through StoreKit's test harness, so that decision lives
in `EntitlementService.grantsAccess(expirationDate:revocationDate:)` and is tested directly.

**The bundle identifier is still the placeholder.** StoreKit resolves products by bundle
identifier, so the live subscription will not load until `PRODUCT_BUNDLE_IDENTIFIER` matches the
registered app.

## Size

| | |
|---|---|
| App bundle | ~117 MB, almost all of it the big NNUE network |
| Repository | ~112 MB of checked-in networks |
| Memory while analysing | ~380 MB with one engine, ~100 MB per further engine (one shared copy of the networks); about 0.9 GB with all five |

That is the real cost of Stockfish 18. If it is too much, the options are: ship only the small net
(weaker, and Stockfish wants both), or fetch the big net with On-Demand Resources on first launch
(which breaks "bundle nets for offline use" in §2).

## Layout

```
Vendor/
  Stockfish/    Stockfish 18 sources with its AUTHORS and Copying.txt; one patch in src/shm.h (NOTICE.md)

ChessAnalyser/
  App/          AppModel (the only place services are wired), RootView, debug fixtures
  Core/Chess/   Board, move generation, make/unmake, SAN, PGN, Zobrist
  Core/Domain/  Players, games, analyses, queue, filters, identity
  Engine/       ChessEngine protocol, Stockfish bridge, score types
  Resources/    Bundled NNUE networks and the GPLv3 text shown in the app
  Analysis/     Policy and scoring, detectors, per-game analyzer, worker and coordinator
  Data/         SQLite wrapper, schema, repositories, statistics
  Network/      Chess.com client, archive sync
  Entitlement/  StoreKit 2
  Backup/       Stored-ZIP reader/writer, export, staged import
  UI/           Design tokens, components, board, screens
```

The dependency direction is one-way: `UI → AppModel → use cases → repositories`. The UI never
builds SQL and never talks to the engine.

## Screens

Every ID in [docs/screens.md](../docs/screens.md) has an implemented destination, except two
removed by design: W06 Opening detail (Analytics no longer lists openings) and W10 Continuation
(the review shows Stockfish's top three live lines under the board instead).

| | | |
|---|---|---|
| W01 Welcome | W02 Add player | W03 Importing history |
| W04 Tracked players | W05 Analytics | W07 Games |
| W08 Filters | W09 Game review | W11 Individual analysis (inline on W09) |
| W12 Mistakes | | |
| W13 Mistake category | W14 Bulk preparation | W15 Queue |
| W16 Premium plan | W17 Subscription | W18 Settings |
| W19 Backup & restore | W20 Export | W21 Import preview |
| W22 Import result | W23 Storage & data | W24 Confirmations |
| W25 About & licences | W26 How analysis works | W27 Update username |
| W28 System handoffs (real share sheet, file importer, StoreKit) | | |

## Design

"Night Board": a near-black ground, one amber accent, the system face and tabular figures. Content
sits directly on the ground, split by hairlines rather than boxed in cards; Liquid Glass is used
only for controls that float above it — the system tab bar and toolbars, selectors, and the review
scrubber — as Apple's guidance asks (`UI/Design/Glass.swift`, with a material fallback before
iOS 26). The app runs in dark appearance. The board is a single `Canvas`, edge to edge on the
review screen, with a last-move highlight, check ring, evidence rings and a translucent arrow for
the engine's preference. While analysis runs, the queue shows as an accessory above the tab bar on
iOS 26.1+, and as a toolbar button before that.

Severity is always carried by text as well as colour, charts have a data-table alternative, and
every tappable target is at least 44pt.

## Deliberate choices worth knowing

- **Both compilers are optimised in Debug** (`SWIFT_OPTIMIZATION_LEVEL = -O`,
  `GCC_OPTIMIZATION_LEVEL = 3`). The engine is the product: unoptimised, analysis ran about 30×
  slower and the app felt broken. Debugging is correspondingly less steppable; lower it per-target
  if you need that.
- **Bulk analysis runs on several engines and paces itself by how many** (`ThermalPacing`). One
  engine per efficiency core (up to four, fewer on phones with less memory) does most of the work
  side by side: each is several times slower than a performance core but far cheaper in heat, and
  four together search about as fast as one performance core. While the phone is cool, the
  performance-core engine joins them; when it is warm, it drops out; when it is hot, everything
  stops. Each time the phone gets hot while analysing, one efficiency engine comes off, and one
  returns after 20 calm minutes. A review you open yourself always runs on the performance core
  and takes it from bulk work.
- **Analysis speed is budget-bound, not time-bound**, so the same game scores identically on any
  device and on any of its engines. A 40-move game costs 81 root searches at 100k nodes plus about
  0.35 confirmation searches at 500k per ply — about 250k nodes per ply in club games.
- **An interrupted game starts over and reproduces an uninterrupted one exactly.** Nothing is
  saved until a game is complete, which at these budgets takes seconds. The tests stop games part
  way at several points, analyse them on different engines after other games, and compare every
  stored field.
- **A game whose notation cannot be fully read fails visibly.** It stays in your game totals and no
  partial review is published from whatever prefix happened to parse.
- **Premium gates starting bulk work, never reading.** Single-game reviews and every saved review
  work on every plan; a bulk run already queued finishes even if the subscription lapses.

## Not done here

These are the specification's own publication dependencies (§14), not gaps in the build:

- Real Apple bundle and product identifiers, regional pricing and agreements. The included
  `Supporting/Products.storekit` drives a local test purchase; the paywall handles an unavailable
  product without breaking.
- Real source, privacy, terms and support URLs, and the full GPLv3 licence text for a shipped build.
  The About screen marks its placeholders as development values.
- Physical-device benchmarks, StoreKit sandbox lifecycle tests and the source-release audit.
- Background analysis on a physical device. `BackgroundAnalysisController` submits a
  `BGContinuedProcessingTask` on iOS 26+ when you start or resume work (system progress UI; a
  cancellation from that UI becomes a user pause), and an opportunistic `BGProcessingTask`
  (external power, no network) on every version. The simulator does not run either, so both
  still need testing on a phone.
