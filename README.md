# Blunderbook

**Find the move that lost the game.** Blunderbook is an iPhone app that downloads every game a
player has played on Chess.com or Lichess and analyses them on the phone itself with
[Stockfish 19](https://stockfishchess.org). It shows where each game turned, why, and what the
engine would have played instead. No account, no server doing the thinking.

[Website](https://serhiiomelchenko.com/blunderbook-app/) ·
[Privacy](https://serhiiomelchenko.com/blunderbook-app/privacy/) ·
[Terms](https://serhiiomelchenko.com/blunderbook-app/terms/) ·
[Support](https://serhiiomelchenko.com/blunderbook-app/support/)

**Status:** in testing ahead of an App Store release.

## What it does

- **Your whole history.** Add any public Chess.com or Lichess username and every game comes down.
  Each account is tracked on its own.
- **Stockfish on the device.** Every position is searched by Stockfish 19 running in the app,
  and its evaluations are kept exactly as given.
- **One game, in depth.** Open a game and every move is scored by how far it moved the evaluation
  bar, with key moments, Stockfish's three best lines for any position, and accuracy.
- **Three accuracy rings:** this game, the last 30 days and the last 12 months, measured the same
  way for both sites.
- **Mistakes, drilled.** Errors from your reviews in one list, the pattern costing you most, and
  each position handed back to you to find the better move (Premium).

## Build

```sh
open ios/Blunderbook.xcodeproj
```

Stockfish's 94 MB neural network is not checked in. Fetch it before the first build:

```sh
curl -fL -o ios/Blunderbook/Resources/Networks/nn-1a298aa575a0.nnue \
  https://tests.stockfishchess.org/api/nn/nn-1a298aa575a0.nnue
```

Build instructions, tests, debug launch arguments, architecture and design notes are in
[`ios/README.md`](ios/README.md).

## Repository

| Path | What it is |
|---|---|
| [`ios/`](ios/) | The app: Swift and SwiftUI, vendored Stockfish, tests |
| [`ios/NOTICE.md`](ios/NOTICE.md) | Every third-party component, its licence, and the one modified Stockfish file |
| [`chess-ios-app-spec.md`](chess-ios-app-spec.md) | The original development specification |
| [`docs/`](docs/) | The screen inventory and the implementation plan from the design phase |
| [`wireframes/`](wireframes/) | Interactive HTML wireframes of every screen; open `wireframes/index.html` in a browser |

The specification, docs and wireframes predate the implementation. Where they differ from the
app, the app is the reference.

## Licence

Blunderbook links Stockfish, so the whole app is free software under the
[GNU General Public License v3.0](LICENSE) or later. The chess pieces are Colin M.L. Burnett's
cburnett set (GPLv2 or later) and opening names come from Lichess's chess-openings data (public
domain); [`ios/NOTICE.md`](ios/NOTICE.md) has the details. Each App Store release is tagged in this
repository, so the corresponding source of any build can be found.

Blunderbook is an independent project, not affiliated with Chess.com or Lichess.
