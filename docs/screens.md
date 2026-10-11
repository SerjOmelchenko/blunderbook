# Screen and state contract

Open [the interactive atlas](../wireframes/index.html). It works directly from disk with no server or dependency installation. “View all screens” shows all 28 default layouts; use the individual screen’s state selector to inspect variations. Phone content scrolls. “Print atlas” switches to the complete gallery before printing.

The [specification](../chess-ios-app-spec.md) controls calculations, entitlement and persistence. This inventory controls destinations and state behavior. The HTML is a clickable content/layout prototype: figures are fixtures, network/purchases/deletions never run, and native Apple interfaces are schematic.

## Screen inventory

| ID / destination | Alternate states in atlas | Required behavior |
|---|---|---|
| W01 Welcome | Default | Add player → W02; import → W28 picker. No required account/paywall. |
| W02 Add player | Resolved, invalid, not found, offline | Validate input; resolve and confirm provider identity before tracking. Duplicate identity switches to existing profile. |
| W03 Importing history | Partial, complete, empty, offline, rate limited | Show metadata as available, preserve prior scope until bounded refresh completes; leave/retry without data loss. |
| W04 Tracked players | Unavailable username | Select context, add player, update username, remove with confirmation. Free plan tracks one player: "Add another player" carries a lock and opens W16. Players kept from before the limit stay selectable. |
| W05 Analytics | Bullet, blitz, Daily, other player, no analysis, empty, offline, premium | Shared filters; class-specific rating; plan scope and matched analysis coverage. Daily is separate. |
| W06 Opening detail | Unknown opening, no analysis | Metadata-derived opening group; matching games; no invented opening/accuracy. |
| W07 Games | Saved reviews, premium, empty, offline, filtered | All games/Analysed games segments; filters; bulk preparation/paywall; queue; refresh. Saved reviews retain scope badges. Each row ends with the accuracy figure and three rings (updated 2026-10-11): this game outside, then the player's mean accuracy over the 30 days and the 12 months up to that game, same time class, deep reviews only. A green check in the centre when every error from the game is solved (also when it has none). Unreviewed: grey empty rings; tapping them queues a deep review in place. Queued or analysing: short arcs spin (no "Queued" text); when the review lands they settle into their values one after another, the figure counts up, the check appears, and the animation stops. Reduce Motion: a pulse and a short fade instead. Tapping finished rings opens W12 narrowed to that game (the free plan gets the Mistakes preview). The rest of the row opens W09. Failed keeps its text. |
| W08 Filters | Applied, rating data | Apply/cancel/reset. Class/date/color/rated shared across tabs; review status local to list. Rating data is the accessible chart alternative. |
| W09 Game review | Analysing, waiting, paused, analysed in depth, mate, flipped, zero moves, failed | Opening a game starts its in-depth analysis (deep-v1) unless it has one; no separate analyse button. Opening name (ECO + name, from the bundled Lichess list) above the evaluation line, with "Book" on book moves; book moves also get a book badge on the board and in the move strip. Horizontal evaluation line on top, edge-to-edge board with sliding pieces, verdict badge and best-move arrow, compact three live lines, graph (or analysis progress in the same slot) and move strip. Step controls sit in their own row below the review, never over it: previous move far left, Next mistake centred, next move far right. On iPhone 16–18 the whole review fits one screen with no scrolling or overlap (the board takes the height left, up to full width); accessibility text sizes scroll. Swipe on the board to step. No per-move text block. Explore (W29) from the toolbar. |
| W10 Continuation | Next reply, development, actual game | Distinguish actual from hypothetical, step through legal PV, retain original review position on return. No practice/retry. |
| W11 Individual analysis | Paused, complete, failed, thermal | Progress; stop/checkpoint; retry; saved complete review. No final game metrics while incomplete. |
| W12 Mistakes | Flat list since 2026-10-10 | One list of the player's errors across deep-reviewed games, newest first, no nested screens. Each card shows the move, its severity and labels for the kind of mistake: the patterns a line demonstrates (Hanging piece, Missed capture, Allowed/Missed fork, Allowed pin, Allowed/Missed mate), or when none applies its consequence (Lost material, Missed material, Let a win slip, No forcing line). Never "Unknown". A row of kind chips with counts narrows the list in place. A card opens the mistake as a puzzle; solved ones carry a check. Empty state points to opening a game. Narrowed to one game from W07 (2026-10-11): a pill above the figures names the game and its ✕ widens to every game again; the figures and the empty state then speak of that game, and the other filters are set aside so they cannot hide it. |
| W12a Mistakes preview | Free plan, trial eligible, trial used | Opened by the locked Mistakes tab (lock symbol, never selected) and by the review screen's mistake tray. What the tab does in three rows, then the real W12 layout on six sample positions: kind filter, drills (solving ticks the sample until the sheet closes; no "Open game"), explore. Pinned "Start 7-day free trial" / "Unlock with Premium" opens W16; subscribing closes it onto the real tab. |
| W13 Mistake category | Removed 2026-10-10 | Replaced by the kind labels and in-place filter on W12. |
| W14 Bulk preparation | Estimating, free, incomplete history | Selected player; completed/skipped/new counts; provisional active-time range; start/cancel; free → plan. |
| W15 Queue | Manual pause, heat, battery, Low Power Mode, expiry, storage, failed, complete, system wait | Durable progress; multiple blockers; pause/resume/cancel; retry failed; retained reviews. |
| W16 Premium plan | Product loading, trial eligible, trial used, pending, failed, restored | "Every feature, one plan." Free vs Premium rows: open a game, Mistakes, review depth (up to 23 / up to 29), 100 at once, players (1 / unlimited), saved games. Localized monthly product with its 7-day free trial while eligible ("Free for 7 days, then …", "Start 7-day free trial", trial terms); subscribe, restore, terms/privacy, dismiss. Never promise restore recovers local data. |
| W17 Subscription | Free, trial, expired, checking, grace | Verified entitlement and next renewal when known; system manage; restore/renew; unknown status does not erase reviews. |
| W18 Settings | Default | Players, subscription, review depth (four confirmation budgets, depth 19 default; depth 26 and 29 locked on the free plan and open W16), backup, storage, methods, licenses. No app account or cloud. |
| W19 Backup & restore | Default | Contents and exclusions; create/export, system picker/import. Privacy and app-deletion warning. |
| W20 Export | Ready, share returned, failed, canceled | Consistent snapshot; progress/cancel; share/save file. Share return is not proof of durable external storage. |
| W21 Import preview | Conflicts, invalid, newer schema, low storage | Validate/stage first; counts and conflict policy before commit; choose another/cancel. |
| W22 Import result | Failed, canceled | Atomic result; original unchanged on error/cancel. Scope requires refresh verification. |
| W23 Storage & data | Low storage, cleared | Usage, backup-first, exact per-player/all-data scope; no automatic review deletion. |
| W24 Confirmation | Clear analysis, remove player, clear all, cancel queue | Explain impact and preserved data; confirm/cancel. Shared references protected. |
| W25 About & licenses | License, privacy, terms, source | Versioned build/source; full release license texts and real links. Prototype legal content is explicitly unfinished release content. |
| W26 How analysis works | Default | Search budget, evaluation-bar formula, live lines and versions. No provider metric equivalence claim. |
| W27 Update username | Matched ID, mismatch, offline | Relink only verified same provider ID. Different ID can only be tracked separately. |
| W28 Native handoffs | File picker, purchase, manage, share | Document system entry/return paths, purchase approval/cancellation. Apple owns final appearance. |
| W29 Explore | Both sides, against engine, engine thinking, game over, warm phone | Added 2026-10-10. Opened from W09 (branch icon in the toolbar, from the move on screen with the game's history) and from the mistake puzzle (the position before the mistake). Play moves that never happened: for both sides, or for your own side while the engine answers with the best of its live lines. Segmented mode switch above the evaluation line; same column as W09 (edge-to-edge board, status line, three live lines, line strip starting at "Game"). A move earlier in the line branches and drops the rest; against the engine, back takes your move back past the engine's reply. Promotion asks for the piece. Board is outlined while off the game's position. Back to game drops the line. Nothing is stored or counted. |

## Navigation contract

First launch → W01 → W02 → W03 → W07. Subsequent launch restores selected player/tab and cached content. Two root tabs are W05/W07; each has shared Players (W04) and Settings (W18). A successful player switch keeps the selected tab when possible.

Review entry may come from Games, Opening detail, an error occurrence, saved reviews or the queue. Preserve the originating screen, filter, scroll and selected ply. Continuation is a child of Review; navigating its hypothetical board must never mutate actual moves. Filter sheets cancel without applying. Completed individual analysis returns to that game, not an unrelated list.

Bulk: Games → W14 for premium / W16 for free → W15. Paywall dismissal returns to the caller. A verified purchase may continue the original requested action after reconfirming bulk scope; never start a large batch just because billing succeeded. Cancellation requires W24; user Pause does not.

Backup: Settings → W19 → W20 → native share. Import: W19 (or Welcome) → native picker → W21 → W22. Picker dismissal returns to its original caller; validation failure leaves the database untouched. Destructive actions route to Welcome only when the last player is removed.

## Global state requirements

- Cached content + freshness indicator is different from an empty database. Keep context and offer retry for offline/provider failures.
- Coverage states: none / some / complete / incomplete jobs / failed games / excluded older policy. Do not imply unreviewed games are error-free.
- Scope states: free eligible / saved outside window / premium / unverified imported scope. Never hide a retained review behind a purchase prompt.
- Purchase states: loading / unavailable / pending / canceled / verified active / grace / expired / revoked / offline-known / unknown. One billing error must not erase data.
- Queue reasons compose. Display primary reason and expose additional reasons. Recovery, charging or renewal does not cancel a manual pause.
- All destructive destinations preserve another tracked player's shared data and explain subscription/backup independence.
- Dynamic Type, VoiceOver labels, color-independent outcomes and evaluation-bar changes, chart data tables, portrait/landscape and minimum 44pt targets are native implementation requirements.

## Prototype conventions and deliberate shortcuts

The atlas emphasizes coverage over simulated app state. Each screen/state is directly addressable (`#W15/heat`); switching states does not mutate a live database. Buttons demonstrate destinations. Filters are visual examples; Apply goes to a representative filtered list. Player lookup accepts nonempty simple input and displays the fixed fixture, not a real profile. The prototype uses representative back destinations; native implementation must preserve the true caller as specified above.

The default board example uses the legal sequence `1. f3 e5 2. g4 Qh4#`; illustrative alternative `2. e4 Nf6 3. Nc3`. The no-errors view uses a separate short draw fixture. These prove layout/navigation, not measured Stockfish output. Other game rows and statistical states are independent examples. The state selector exposes conditions that cannot arise from the default fixture. Apple purchase/file/share screens are explanatory diagrams, not custom replacements for system UI.

Final visual branding, production iconography and native chart/board interaction details follow during implementation. A static HTML inspection cannot verify iOS background execution, billing, chess correctness or native accessibility.
