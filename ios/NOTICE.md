# Third-party components and build manifest

Blunderbook as a whole is distributed under the GNU General Public License version 3 or
later. See [LICENSE](LICENSE) for the full text.

**Additional term under GPLv3 section 7(e).** "Blunderbook" and the Blunderbook icon
(`Blunderbook/AppIcon.icon`) are trademarks of Serhii Omelchenko, and no rights to them are
granted under this licence. Anyone who distributes a modified version must give it a different
name and icon and must not present it as the official Blunderbook. This term limits only the use
of the name and icon; it does not restrict any right the GPL grants over the code.

## Stockfish

The app links Stockfish directly into its binary. Linking makes the combined application a work
based on Stockfish, which is why the entire app — interface, analysis pipeline, tagging logic and
all — is GPLv3 rather than only the vendored directory.

| | |
|---|---|
| Component | Stockfish |
| Version | Stockfish 19 (tag `sf_19`, released 2026-09-05; replaced Stockfish 18 on 2026-10-10) |
| Source commit | `edb0d9db6731067ec50ce619ff372b463bc4dd5d` |
| Upstream | https://github.com/official-stockfish/Stockfish |
| Licence | GNU General Public License v3 or later |
| Copyright | 2004–2026 The Stockfish developers (see `Vendor/Stockfish/AUTHORS`) |
| Location in this repository | `Vendor/Stockfish/` |
| Modified? | **Yes, one file.** `src/main.cpp`, `src/Makefile` and `src/universal/` (multi-architecture launchers for desktop builds) are omitted, because an app target supplies its own entry point and build system. `src/shm.h` is modified, marked in the file, in two places. (1) 2026-10-10: Stockfish 19's system-wide POSIX shared-memory backend is turned off on iOS, where the app sandbox has no `/tmp` or `shm_open`. (2) 2026-10-04: without such a backend, Stockfish's fallback gives every `Engine` its own copy of the network. The app runs several engines at once, so the fallback now shares one read-only copy between engines in the same process, keyed by the network's content hash. Search results are unchanged. No other Stockfish source file has been edited. |

Stockfish's own licence text is kept alongside its sources at `Vendor/Stockfish/Copying.txt`, and
its author list at `Vendor/Stockfish/AUTHORS`.

## Neural networks

Stockfish evaluates positions with an NNUE network, which is also GPLv3. Stockfish 19 uses one
network where 18 used a big and a small one. Stockfish names each
network after its own SHA-256 prefix, so the filename is the checksum.

| Network | SHA-256 | Size |
|---|---|---|
| `nn-1a298aa575a0.nnue` | `1a298aa575a085434d29027978dc36867fe9c5bcea9376654b7a8eba1e52dfc2` | 98,511,183 bytes |

It is bundled in the app for offline use, at `Blunderbook/Resources/Networks/`. Nothing is
downloaded at runtime.

Verify them with:

```sh
shasum -a 256 Blunderbook/Resources/Networks/*.nnue
```

## Build configuration

Stockfish is compiled from the vendored sources by the app target with:

- `-std=c++17`, `-O3`, `libc++`
- `IS_64BIT=1`, `USE_NEON=8` — equivalent to Stockfish's own `apple-silicon` profile
- `NNUE_EMBEDDING_OFF=1` — networks are loaded from the app bundle rather than embedded in the
  binary by `incbin`

Stockfish is the app's only source of analysis. There is no second engine.

## Board artwork

The chess pieces are the **cburnett** set — the drawings Colin M.L. Burnett made for Wikipedia,
also used by Lichess. They are licensed GPLv2 *or later*, so this app uses them under version 3,
which is what the "or later" clause exists for.

| | |
|---|---|
| Component | cburnett piece set |
| Artist | Colin M.L. Burnett |
| Upstream | https://github.com/lichess-org/lila/tree/master/public/piece/cburnett |
| Licence | GNU General Public License v2 or later |
| Location in this repository | `Blunderbook/Assets.xcassets/piece-*.imageset/` |
| Modified? | **No.** The twelve SVGs are included verbatim. Each is wrapped in an asset-catalogue `Contents.json` so Xcode preserves the vector data, which does not alter the artwork. |

Only the pieces are third-party. The board, its squares, coordinates, highlights and move arrows
are drawn by the app in `BoardView.swift`.

## Opening names

Opening names and the book of known opening moves come from the Lichess **chess-openings** data
set, a list of about 3,900 named lines with their ECO codes.

| | |
|---|---|
| Component | lichess-org/chess-openings (`a.tsv` to `e.tsv`) |
| Upstream | https://github.com/lichess-org/chess-openings |
| Licence | Public domain; CC0 1.0 where copyright applies |
| Retrieved | 2026-10-08, `master` branch |
| Location in this repository | `Blunderbook/Resources/Openings.tsv` |
| Modified? | **No.** The five files are joined into one, with a single header row. |

## Everything else

No other third-party code, assets, fonts or icons are included. The remaining dependencies are
Apple system frameworks (SwiftUI, Swift Charts, StoreKit, UIKit, CryptoKit, the SDK's SQLite),
which are used under Apple's own terms and are not distributed with this source.

If you add a further piece set, font or icon pack later, it must carry a GPLv3-compatible licence
and be listed here.
