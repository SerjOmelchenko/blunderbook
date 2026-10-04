# Third-party components and build manifest

Chess Analyser as a whole is distributed under the GNU General Public License version 3 or
later. See [LICENSE](LICENSE) for the full text.

## Stockfish

The app links Stockfish directly into its binary. Linking makes the combined application a work
based on Stockfish, which is why the entire app — interface, analysis pipeline, tagging logic and
all — is GPLv3 rather than only the vendored directory.

| | |
|---|---|
| Component | Stockfish |
| Version | Stockfish 18 (tag `sf_18`) |
| Source commit | `cb3d4ee9b47d0c5aae855b12379378ea1439675c` |
| Upstream | https://github.com/official-stockfish/Stockfish |
| Licence | GNU General Public License v3 or later |
| Copyright | 2004–2026 The Stockfish developers (see `Vendor/Stockfish/AUTHORS`) |
| Location in this repository | `Vendor/Stockfish/` |
| Modified? | **Yes, one file.** `src/main.cpp` and `src/Makefile` are omitted, because an app target supplies its own entry point and build system. `src/shm.h` is modified (2026-10-04, marked in the file): Apple platforms have no shared-memory backend, so Stockfish's fallback gave every `Engine` its own copy of the networks. The app runs several engines at once, so the fallback now shares one read-only copy between engines in the same process, keyed by the network's content hash. Search results are unchanged; with the app's 64 MiB hash, each extra engine costs about 97 MB instead of about 229 MB. No other Stockfish source file has been edited. |

Stockfish's own licence text is kept alongside its sources at `Vendor/Stockfish/Copying.txt`, and
its author list at `Vendor/Stockfish/AUTHORS`.

## Neural networks

Stockfish evaluates positions with NNUE networks, which are also GPLv3. Stockfish names each
network after its own SHA-256 prefix, so the filename is the checksum.

| Network | SHA-256 | Size |
|---|---|---|
| `nn-c288c895ea92.nnue` (big) | `c288c895ea924429ea9092e3f36b2b3c1f00f2a3a4c759ff7e57e79e3b43e4a7` | 108,919,594 bytes |
| `nn-37f18f62d772.nnue` (small) | `37f18f62d772f3107e1d6aaca3898c130c3c86f2ab63e6555fbbca20635a899d` | 3,519,630 bytes |

Both are bundled in the app for offline use, at `ChessAnalyser/Resources/Networks/`. Nothing is
downloaded at runtime.

Verify them with:

```sh
shasum -a 256 ChessAnalyser/Resources/Networks/*.nnue
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
| Location in this repository | `ChessAnalyser/Assets.xcassets/piece-*.imageset/` |
| Modified? | **No.** The twelve SVGs are included verbatim. Each is wrapped in an asset-catalogue `Contents.json` so Xcode preserves the vector data, which does not alter the artwork. |

Only the pieces are third-party. The board, its squares, coordinates, highlights and move arrows
are drawn by the app in `BoardView.swift`.

## Everything else

No other third-party code, assets, fonts or icons are included. The remaining dependencies are
Apple system frameworks (SwiftUI, Swift Charts, StoreKit, UIKit, CryptoKit, the SDK's SQLite),
which are used under Apple's own terms and are not distributed with this source.

If you add a further piece set, font or icon pack later, it must carry a GPLv3-compatible licence
and be listed here.
