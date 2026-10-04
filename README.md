# Chess Games Analyser

iOS app blueprint: public Chess.com game history, on-device Stockfish analysis, retained reviews and evidence-based mistake explanations.

- [Development specification](chess-ios-app-spec.md) — scope, algorithms, persistence, billing and acceptance criteria.
- [Interactive wireframes](wireframes/index.html) — all 28 screens, alternate states and clickable flows. Open the HTML in a browser; no server needed.
- [Screen/state contract](docs/screens.md) — navigation, failure states and prototype limitations.
- [Implementation plan](docs/development-plan.md) — build order, exit criteria and test fixtures.

This repository currently contains the development blueprint, not an implemented iOS app. Engine performance, physical-device behavior, configured Apple products and distribution review remain implementation/release tasks.

## Wireframe verification

`node --check wireframes/app.js` checks script syntax. With Playwright installed outside or inside your chosen QA environment, run:

```sh
node wireframes/qa.mjs /absolute/path/to/node_modules/playwright/index.mjs
```

The script uses a disposable headless Chrome profile, checks every defined screen/state and route, tests representative interactions at desktop/mobile sizes, and writes previews plus a JSON report to `wireframes/qa/`. It does not connect to Chess.com or perform purchases/file imports. Chrome's default macOS executable path can be overridden with `CHESS_QA_CHROME`.
