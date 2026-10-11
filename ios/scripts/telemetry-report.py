#!/usr/bin/env python3
"""Summarises the bulk-analysis performance log pulled by telemetry-pull.sh.

    scripts/telemetry-report.py [dir-or-files...] [--since MINUTES]

Answers: where did the wall-clock time go, how fast does the engine search under each device
condition, and how long would the remaining queue take at the rates actually seen.
"""
import argparse
import datetime as dt
import json
import os
import statistics
import sys
from collections import defaultdict

INTERVAL = 15  # seconds between samples, AnalysisCoordinator.telemetryInterval


def load(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            # Rotated file first: it holds the older lines.
            files += [os.path.join(path, name) for name in ("telemetry.1.jsonl", "telemetry.jsonl")
                      if os.path.exists(os.path.join(path, name))]
        else:
            files.append(path)
    lines = []
    for name in files:
        with open(name) as handle:
            for raw in handle:
                try:
                    lines.append(json.loads(raw))
                except json.JSONDecodeError:
                    pass  # a line cut off by the app being killed mid-write
    return sorted(lines, key=lambda line: line["t"])


def clock(t):
    return dt.datetime.fromtimestamp(t).strftime("%d %b %H:%M:%S")


def hours(seconds):
    return f"{seconds / 3600:.1f} h" if seconds >= 3600 else f"{seconds / 60:.0f} min"


def work_totals(work):
    budgets = work.get("budgets", {})
    return {
        "searchSeconds": sum(b["seconds"] for b in budgets.values()),
        "nodes": sum(b["nodes"] for b in budgets.values()),
        "searches": sum(b["searches"] for b in budgets.values()),
    }


def live(sample):
    """The part of a sample's interval the process was running. The sampler fires every INTERVAL
    seconds while it runs, so anything longer is time iOS kept the app frozen."""
    return min(sample["interval"], 1.5 * INTERVAL)


def is_working(state):
    return state.startswith("working")


def state_of(sample):
    c = sample["conditions"]
    if c["blockers"]:
        return "blocked:" + "+".join(c["blockers"])
    if c["suspendedForBackground"]:
        return "stopped (background, no time granted)"
    busy = c.get("activeGames", 1 if c.get("analysing") else 0)
    if not busy and not sample["work"].get("plies") and not work_totals(sample["work"])["searches"]:
        return "idle (nothing to analyse)"
    return "working · on screen" if c["appState"] == "active" else "working · background"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", default=[os.path.join(os.environ.get("TMPDIR", "/tmp"),
                                                                  "chessanalyser-telemetry")])
    parser.add_argument("--since", type=float, help="only the last N minutes")
    args = parser.parse_args()

    lines = load(args.paths)
    if args.since and lines:
        cutoff = lines[-1]["t"] - args.since * 60
        lines = [line for line in lines if line["t"] >= cutoff]
    samples = [line for line in lines if line.get("event") == "sample"]
    if not samples:
        print("No samples yet.")
        return

    launches = [line for line in lines if line.get("event") == "launch"]
    if launches:
        last = launches[-1]
        print(f"Device {last.get('model')} · {last.get('os')} · {last.get('cores')} cores · "
              f"build {last.get('build')} · {last.get('policy')} · {last.get('engine')}")
    span = samples[-1]["t"] - samples[0]["t"] + samples[0]["interval"]
    print(f"Log {clock(samples[0]['t'] - samples[0]['interval'])} → {clock(samples[-1]['t'])} ({hours(span)}), "
          f"{len(samples)} samples, {len(launches)} launches")

    # Where the time went. Every second of the span is either live time in some state, or time the
    # process was frozen or closed (no samples), so the rows add up to the span.
    by_state = defaultdict(float)
    search = rest = 0.0
    for s in samples:
        by_state[state_of(s)] += live(s)
        search += work_totals(s["work"])["searchSeconds"]
        rest += s["work"].get("restSeconds", 0)
    frozen = max(0.0, span - sum(by_state.values()))
    print("\nWHERE THE TIME WENT")
    rows = [("app frozen or closed by iOS", frozen)] + list(by_state.items())
    for state, seconds in sorted(rows, key=lambda item: -item[1]):
        print(f"  {state:<38} {hours(seconds):>9}  {100 * seconds / span:5.1f}%")
    working = sum(seconds for state, seconds in by_state.items() if is_working(state))
    if working:
        print(f"    engine-seconds per working second: {search / working:4.2f} (several engines run at once)")

    # Speed by condition. Several engines can run at once, so throughput is nodes per second of
    # wall time, and each engine's own speed is its nodes per second of searching.
    groups = defaultdict(lambda: defaultdict(float))
    engine_speed = defaultdict(lambda: [0.0, 0.0])
    for s in samples:
        if not is_working(state_of(s)):
            continue
        c = s["conditions"]
        engines = c.get("engines") or f"{c.get('workload', '?')}/rest {c.get('restRatio', 0):g}"
        key = (c["thermal"], "charging" if c["charging"] else "battery", engines, c["appState"])
        g = groups[key]
        w = s["work"]
        g["seconds"] += live(s)
        g["cpu"] += s.get("cpuSeconds", 0)
        g["plies"] += w.get("plies", 0)
        g["nodes"] += work_totals(w)["nodes"]
        g["rest"] += w.get("restSeconds", 0)
        for name, e in w.get("engines", {}).items():
            engine_speed[(name, c["thermal"])][0] += e["nodes"]
            engine_speed[(name, c["thermal"])][1] += e["seconds"]
    print("\nSPEED BY CONDITION (working time only)")
    print(f"  {'thermal':<9}{'power':<9}{'engines':<16}{'app':<11}{'time':>8}{'cores':>6}{'kn/s':>7}{'s/ply':>7}")
    for key, g in sorted(groups.items(), key=lambda item: -item[1]["seconds"]):
        per_ply = g["seconds"] / g["plies"] if g["plies"] else float("nan")
        print(f"  {key[0]:<9}{key[1]:<9}{key[2]:<16}{key[3]:<11}{hours(g['seconds']):>8}"
              f"{g['cpu'] / g['seconds']:>6.2f}{g['nodes'] / g['seconds'] / 1000:>7.0f}{per_ply:>7.3f}")
    if engine_speed:
        print("\n  per engine while searching (kn/s):")
        for (name, thermal), (nodes, seconds) in sorted(engine_speed.items()):
            if seconds:
                print(f"    {name:<4}{thermal:<9}{nodes / seconds / 1000:>7.0f}")

    # Work mix.
    plies = sum(s["work"].get("plies", 0) for s in samples)
    confirmed = sum(s["work"].get("confirmedPlies", 0) for s in samples)
    shared = sum(s["work"].get("sharedConfirmations", 0) for s in samples)
    budgets = defaultdict(lambda: defaultdict(float))
    for s in samples:
        for budget, b in s["work"].get("budgets", {}).items():
            for field in ("searches", "seconds", "nodes"):
                budgets[budget][field] += b.get(field, 0)
    print("\nWORK MIX")
    if plies:
        extra = f" · {100 * confirmed / plies:.1f}% confirmed · {shared} confirmations shared" if confirmed else ""
        print(f"  {plies} plies{extra}")
    for budget, b in sorted(budgets.items(), key=lambda item: int(item[0])):
        print(f"  {int(budget):>7} nodes: {b['searches']:.0f} searches, {hours(b['seconds'])} "
              f"({100 * b['seconds'] / search if search else 0:.0f}% of engine time)")

    # Games.
    ended = [line for line in lines if line.get("event") == "gameEnded"]
    if ended:
        outcomes = defaultdict(int)
        for line in ended:
            outcomes[line["outcome"]] += 1
        rates = [line["seconds"] / line["work"]["plies"] for line in ended
                 if line["outcome"] == "finished" and line["work"].get("plies")]
        print("\nGAMES  " + " · ".join(f"{n} {k}" for k, n in sorted(outcomes.items())))
        if rates:
            print(f"  wall s/ply per finished game: median {statistics.median(rates):.2f}, "
                  f"best {min(rates):.2f}, worst {max(rates):.2f}")

    # Projection.
    pending = samples[-1]["conditions"]["pendingPlies"]
    print(f"\nQUEUE  {samples[-1]['conditions']['pendingGames']} games · {pending} plies left")
    if working and plies:
        rate = working / plies
        print(f"  at this log's working rate ({rate:.2f} s/ply): {hours(pending * rate)} of working time")
        best = min((g["seconds"] / g["plies"] for g in groups.values() if g["plies"] and g["seconds"] >= 120),
                   default=None)
        if best:
            print(f"  at the best condition seen ({best:.2f} s/ply): {hours(pending * best)}")

    # Thermal timeline.
    print("\nTIMELINE (changes only)")
    previous = None
    for s in samples:
        c = s["conditions"]
        engines = c.get("engines") or c.get("workload", "?")
        state = (c["thermal"], c["charging"], engines, c["appState"], state_of(s))
        if state != previous:
            battery = f"{c['battery'] * 100:.0f}%" if c["battery"] is not None else "?"
            print(f"  {clock(s['t'])}  {c['thermal']:<6} {'⚡' if c['charging'] else ' '} {battery:>4}  "
                  f"{engines:<9} {c['appState']:<10} {state[4]}")
            previous = state


if __name__ == "__main__":
    sys.exit(main())
