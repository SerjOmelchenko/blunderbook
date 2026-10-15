# Blunderbook — iOS app

An iPhone app that downloads any public Chess.com or Lichess player's completed games, analyses
them on the device with Stockfish 19, and shows how every move moved the evaluation bar. It was
built from the [development specification](../chess-ios-app-spec.md); where the two differ, this
code is the reference.

**Licence: GPLv3.** The app links Stockfish, so the whole application is GPLv3. See
[LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). The name "Blunderbook" and its icon are trademarks
and are not licensed under the GPL: a fork you publish needs its own name and icon.

## Build and run

```sh
open ios/Blunderbook.xcodeproj
```

Select the **Blunderbook** scheme and an iPhone simulator (or your device), then run. Requires
Xcode 16 or newer; it is built and tested with Xcode 27 against the iOS 27 SDK, with a deployment
target of iOS 17.0.

There are no package dependencies and no CocoaPods. Stockfish is vendored as source under
`Vendor/Stockfish/` and compiled by the app target. Its NNUE network is bundled for offline use
but **not checked in** (it is 94 MB, too close to GitHub's 100 MB file limit). Fetch it once
before the first build:

```sh
curl -fL -o Blunderbook/Resources/Networks/nn-1a298aa575a0.nnue \
  https://tests.stockfishchess.org/api/nn/nn-1a298aa575a0.nnue
shasum -a 256 Blunderbook/Resources/Networks/nn-1a298aa575a0.nnue   # must start 1a298aa575a0
```

Without it the app runs, says analysis is unavailable, and keeps saved reviews readable.

The bundle identifier is `com.example.chessanalyser` (it is the App Store record's identifier, so
it stays) and the team is `78873P6WBY`. To build under your own account, change both under
*Signing & Capabilities*.

Tests:

```sh
xcodebuild test -project ios/Blunderbook.xcodeproj -scheme Blunderbook \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skip-testing:BlunderbookTests/SubscriptionTests
```

Over 200 tests. The analysis tests drive real Stockfish on more than one engine, which is the
point of them. `SubscriptionTests` is skipped above because, in the simulator, StoreKit answers
from the App Store sandbox and a purchase test waits for an Apple Account sign-in.

### Trying it without waiting for a download

```sh
xcrun simctl launch booted com.example.chessanalyser -seed-demo
```

`-seed-demo` loads ten real games for a fictional `demoplayer` (opponents are `opponent1`…) and queues
some of them for analysis. These launch arguments are `#if DEBUG` only and do nothing in a release build:

| Argument | Effect |
|---|---|
| `-seed-provider lichess` | Makes the demo player a Lichess one |
| `-start-tab analytics\|games\|mistakes` | Opens on that tab |
| `-open-game demo-0 [-ply N]` | Opens a game, optionally at a move |
| `-explore both\|engine` | With `-open-game`: Explore from that move |
| `-open-route queue\|how\|about\|first-mistake` | Opens that screen |
| `-open-sheet settings\|players\|paywall\|mistakes-preview\|filters` | Opens that sheet |
| `-queue-game demo-3` | Queues that game's review a moment after launch |
| `-unlock-mistakes` | Opens the Mistakes tab without Premium |
| `-time-class …`, `-date-range week\|month\|90\|year\|all` | Presets the shared filter |
| `-scroll-to leak\|kinds`, `-scroll-bottom` | Opens a long screen part-way down |
| `-tip …`, `-reset-tips`, `-reset-trial-offer`, `-trial-eligible`, `-leave-game` | First-run tips and the trial offer |

For the ordinary path, run the app and add a real Chess.com or Lichess username.

## What works end to end

Add a player → their monthly archives download → games appear → open a game and it is analysed in
depth → a saved review with an evaluation graph, each move's effect on the evaluation bar, accuracy,
and Stockfish's three live lines for any position → mistakes collected and drilled → export and
re-import everything.

| Area | State |
|---|---|
| Chess rules | Complete. Passes perft to depth 5 on six standard positions, full SAN in and out, PGN with comments, variations, NAGs and `SetUp`/`FEN`. |
| Engine | Stockfish 19, vendored and compiled in-process. The only source of analysis. |
| Analysis | Every position is searched once at 100,000 nodes (policy `eval-v1`) and the evaluation stored as given. A game you open is analysed in depth (`deep-v1`): every position at the review depth set in Settings, every move scored, with accuracy, phase, patterns and the best move. |
| Review depth | Quick 500k (default) · Standard 1.5M (about what Lichess gives) · Deep 3M · Deepest 6M nodes per position. Deep and Deepest come with Premium. |
| Accuracy | Lichess's published method, the same for Chess.com and Lichess games. Three rings: this game, the last 30 days, the last 12 months. |
| Mistakes | Errors from in-depth reviews in one list, the biggest leak, opening hot spots, and a drill that asks for the better move (Premium). |
| Persistence | SQLite via `sqlite3` behind typed repositories, WAL, foreign keys, versioned transactional migrations, 50-row paging. |
| Provider | Chess.com Published-Data API with conditional requests, and the Lichess game export streamed as ND-JSON with resumable cursors. One transport: `Retry-After`, jittered backoff, classified failures. Each player belongs to one site; the same name on both is two players. |
| Queue | Durable and deduplicated. The game you are looking at gets every engine; other queued games run on spare engines while the phone is cool. Blockers compose (thermal, battery, Low Power Mode, storage, entitlement). |
| Background | A `BGContinuedProcessingTask` on iOS 26+ (system progress UI; cancelling there pauses) and an opportunistic `BGProcessingTask` on every version. |
| Billing | StoreKit 2 against `monthly_premium` (group "Premium Subscription", 1 month, 1-week free trial, Family Sharing off). Verified entitlements, updates listener, restore, cached valid-through for offline. |
| Backup | Versioned `.chessbackup` (stored ZIP + manifest + NDJSON), staged validation before any write, merge-only atomic commit. |
| UI | Dark appearance, Dynamic Type, VoiceOver labels, chart data alternatives, 44 pt targets, first-run tips shown once each. |

## The engine

**Stockfish 19** (tag `sf_19`, commit `edb0d9db6731`), vendored as source and compiled into the app
by the app target. There is no child process: the bridge drives `Stockfish::Engine` directly
through its C++ API.

| | |
|---|---|
| Search | `go nodes 100000` once per position for `eval-v1`; the review depth for an in-depth review; a deeper three-line search live when a position is shown |
| Settings | Threads 1, Hash 64 MiB per engine, MultiPV 1, full strength, no ponder, Chess960 off |
| Engines | From the device's own core counts: `P − 1` performance-core engines and `⌊E / 2⌋` efficiency-core ones (at least one of each), at most 8 in all and at most one per GiB of memory, so the phone stays usable. All share one copy of the network |
| Network | `nn-1a298aa575a0` (94 MB), bundled |
| Speed | 1.1–1.4M nodes/s on an iPhone 16 Pro performance core, 250–300k per efficiency core, measured with Stockfish 18 |

Two details in `StockfishBridge.mm` matter more than they look:

- **The hash is cleared before every root search.** Without it, results depend on what was
  searched before. This is what makes the app's numbers reproducible, and what lets any engine
  analyse any game with the same result.
- **Positions are sent as a start FEN plus the full move list**, never a bare FEN, so the engine
  sees repetitions and the halfmove clock.

**Stockfish is the only source of analysis.** If the network cannot be loaded, the app says
analysis is unavailable, leaves saved reviews readable, and keeps queued work. It never
substitutes a weaker engine whose results would quietly become incomparable.

## Free plan and Premium

| | Free | Premium |
|---|---|---|
| Analyse any game you open, in depth | Yes, unlimited | Yes |
| Review depth | Quick, Standard | Also Deep, Deepest |
| Tracked players | 1 | Unlimited |
| Mistakes tab and drills | Preview | Yes |
| History downloaded, saved reviews readable | All of it, always | Same |

Premium is the auto-renewing monthly subscription `monthly_premium` with a one-week free trial.
Its price is read from StoreKit at runtime, never hard-coded. The app offers the trial by itself
once, after the first analysed game with something to solve (`TrialOffer.swift`).

`Supporting/Products.storekit` mirrors the product for local testing. In the simulator StoreKit
answers from the App Store sandbox instead, so changes to the product must be made in App Store
Connect as well. Revocation and refund are decided in
`EntitlementService.grantsAccess(expirationDate:revocationDate:)` and tested directly.

## Privacy and usage analytics

Games come straight from the public Chess.com and Lichess APIs; there is no account and no
password. Analysis runs on the device. Purchases go through Apple.

The app sends anonymous usage events to PostHog's EU service (`Network/UsageAnalytics.swift`):
app opened or backgrounded, screens, the site a player was added from, analysis requested,
started and ended (with depth, duration and move count), purchase outcomes and download error
kinds, plus device model, iOS version and app version. Events are typed, so no username, game,
position or error text can be sent. The only identifier is a random ID made on the device and
replaced every 12 months; location lookup and person profiles are off. It is on by default and
switched off under **About › Privacy**, which also drops anything not yet sent. The PostHog key in
the source is a project key, which can only send events.

`PrivacyInfo.xcprivacy` declares the required-reason APIs (UserDefaults, disk space, file
timestamps) and the collected data types. The full policy is at
[serhiiomelchenko.com/blunderbook-app/privacy](https://serhiiomelchenko.com/blunderbook-app/privacy/).

A separate performance log (`Analysis/AnalysisTelemetry.swift`) stays on the device; it is read
over USB with `scripts/telemetry-pull.sh` during development and never sent anywhere.

## Size

| | |
|---|---|
| App bundle | ~103 MB, almost all of it the NNUE network |
| Memory while analysing | ~380 MB with one engine, ~100 MB per further engine (one shared copy of the network), measured with Stockfish 18 |

## Layout

```
Vendor/
  Stockfish/    Stockfish 19 sources with its AUTHORS and Copying.txt; one patch in src/shm.h (NOTICE.md)

Blunderbook/
  App/          AppModel (the only place services are wired), RootView, debug fixtures
  Core/Chess/   Board, move generation, make/unmake, SAN, PGN, Zobrist, opening book
  Core/Domain/  Players, games, analyses, queue, filters, identity
  Engine/       ChessEngine protocol, Stockfish bridge, score types
  Resources/    Bundled NNUE network, opening names and evaluations, the GPLv3 text shown in the app
  Analysis/     Policy and scoring, detectors, per-game analyzer, coordinator, background tasks
  Data/         SQLite wrapper, schema, repositories, statistics
  Network/      Chess.com and Lichess clients, shared transport, sync, usage analytics
  Entitlement/  StoreKit 2
  Backup/       Stored-ZIP reader/writer, export, staged import
  UI/           Design tokens, components (board, rings, first-run tips), screens (incl. trial offer)
  PrivacyInfo.xcprivacy

BlunderbookTests/   XCTest suites for rules, analysis, persistence, providers, billing and more
scripts/            telemetry-pull.sh and telemetry-report.py for on-device performance logs
Supporting/         Info.plist, Products.storekit, bridging header, licence agreement draft
```

The dependency direction is one-way: `UI → AppModel → use cases → repositories`. The UI never
builds SQL and never talks to the engine.

## Design

"Night Board": the app always runs in dark appearance, on a near-black ground with one amber
accent, the system face and tabular figures. Content
sits directly on the ground, split by hairlines rather than boxed in cards; Liquid Glass is used
only for controls that float above it (the tab bar, toolbars, selectors and the review scrubber),
with a material fallback before iOS 26. The board is a single `Canvas`, edge to edge on the review
screen, with a last-move highlight, check ring, evidence rings and a translucent arrow for the
engine's preference.

Whether a move improved or declined the bar is always carried by an arrow and text as well as
colour, charts have a data-table alternative, and every tappable target is at least 44 pt.

## Deliberate choices worth knowing

- **Both compilers are optimised in Debug** (`SWIFT_OPTIMIZATION_LEVEL = -O`,
  `GCC_OPTIMIZATION_LEVEL = 3`). The engine is the product: unoptimised, analysis ran about 30×
  slower. Lower it per target if you need to step through code.
- **Engines pace themselves by heat** (`ThermalPacing`). While the phone is cool, a
  performance-core engine joins the efficiency-core ones on queued work; when it is warm, it drops
  out; when it is hot, everything stops. Each time the phone gets hot, one efficiency engine comes
  off, and one returns after 20 calm minutes.
- **Analysis is budget-bound, not time-bound**, so the same game scores identically on any device
  and on any of its engines.
- **An interrupted game starts over and reproduces an uninterrupted one exactly.** Nothing is
  saved until a game is complete. The tests stop games part way, analyse them on different engines
  after other games, and compare every stored field.
- **A game whose notation cannot be fully read fails visibly.** No partial review is published.
- **Premium never gates reading.** Every saved review works on every plan.

## Before release

Done: the privacy, terms, support and source pages are live at
[serhiiomelchenko.com/blunderbook-app](https://serhiiomelchenko.com/blunderbook-app/) and the app
links to them; the privacy manifest; a real contact address in the provider User-Agent.

Still open:

- App Store Connect: the paid agreement, the subscription's description and trial, the privacy
  answers and the listing.
- Publish this repository and tag each App Store build, so the corresponding source of every
  release can be found.
- Background analysis and StoreKit purchases on a physical device.
- A legal review of `Supporting/EULA-draft.md`, the custom licence agreement that keeps the App
  Store's terms from adding restrictions GPLv3 forbids.
