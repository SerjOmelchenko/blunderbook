#!/bin/zsh
# Copies the bulk-analysis performance log (and optionally the database) off a phone over USB or
# the local network, for scripts/telemetry-report.py.
#
#   scripts/telemetry-pull.sh [-d device-udid] [-o output-dir] [--db]
#
# Without -d it uses the only connected physical device that has the app installed.
set -euo pipefail

BUNDLE_ID="com.example.chessanalyser"
REMOTE_DIR="Library/Application Support/ChessAnalyser"
OUT="${TMPDIR:-/tmp}/chessanalyser-telemetry"
DEVICE=""
WITH_DB=0

while (( $# )); do
  case "$1" in
    -d) DEVICE="$2"; shift 2 ;;
    -o) OUT="$2"; shift 2 ;;
    --db) WITH_DB=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DEVICE" ]]; then
  candidates=("${(@f)$(xcrun devicectl list devices 2>/dev/null \
    | awk '/ connected / && / physical/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i }')}")
  candidates=(${candidates:#})
  if (( ${#candidates} != 1 )); then
    echo "Found ${#candidates} connected phones; pass one with -d." >&2
    exit 1
  fi
  DEVICE="${candidates[1]}"
fi

# Captured first: with pipefail, `grep -q` exiting early would fail the pipeline via SIGPIPE.
devices="$(xcrun devicectl list devices 2>/dev/null || true)"
if ! grep -q "$DEVICE.* connected " <<< "$devices"; then
  echo "Phone $DEVICE is not reachable: plug it in, or unlock it on the same network." >&2
  exit 1
fi

mkdir -p "$OUT"
pull() {
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$REMOTE_DIR/$1" --destination "$OUT/$2" >/dev/null 2>&1
}

pull "Telemetry/telemetry.jsonl" "telemetry.jsonl" || { echo "No telemetry on $DEVICE yet." >&2; exit 1; }
pull "Telemetry/telemetry.1.jsonl" "telemetry.1.jsonl" || rm -f "$OUT/telemetry.1.jsonl"
if (( WITH_DB )); then
  for file in chessanalyser.sqlite chessanalyser.sqlite-wal chessanalyser.sqlite-shm; do
    pull "$file" "$file" || true
  done
fi
echo "$OUT"
