#!/usr/bin/env python3
"""
measure.py — run a command N times, report median/min wall time and peak child RSS.

Portable across macOS and Linux (no `date +%N`, no /usr/bin/time quirks): timing via
time.perf_counter(), memory via resource.getrusage(RUSAGE_CHILDREN).ru_maxrss (bytes on
macOS, KiB on Linux — normalized here). Python is already a hard dependency on the pad.

Usage:
    measure.py --label "node --version" [--reps 10] [--warmup 1] [--cwd DIR]
               [--expect-exit 0] -- <command> [args...]

Emits one JSON line to stdout (consumed by run.sh) and a human summary to stderr.
"""
import argparse
import json
import os
import platform
import resource
import statistics
import subprocess
import sys
import time


def maxrss_to_mb(ru_maxrss: int) -> float:
    # macOS: ru_maxrss is bytes. Linux: kibibytes.
    if platform.system() == "Darwin":
        return ru_maxrss / (1024 * 1024)
    return ru_maxrss / 1024


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--group", default="")
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--warmup", type=int, default=1, help="leading runs to discard (fs warm-up)")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--expect-exit", type=int, default=None,
                    help="if set, runs whose exit != this are flagged (not counted as failure)")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("measure.py: no command given (put it after --)", file=sys.stderr)
        return 2

    walls_ms = []
    exits = []
    rss_before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    peak_rss_raw = rss_before
    total = args.warmup + args.reps
    for i in range(total):
        t0 = time.perf_counter()
        try:
            p = subprocess.run(
                cmd, cwd=args.cwd, timeout=args.timeout,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = -1  # timed out
        t1 = time.perf_counter()
        # ru_maxrss(CHILDREN) tracks the largest terminated child so far → running max.
        cur = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        peak_rss_raw = max(peak_rss_raw, cur)
        if i >= args.warmup:
            walls_ms.append((t1 - t0) * 1000.0)
            exits.append(rc)

    if not walls_ms:
        walls_ms = [float("nan")]

    result = {
        "label": args.label,
        "group": args.group,
        "reps": len(walls_ms),
        "wall_median_ms": round(statistics.median(walls_ms), 1),
        "wall_min_ms": round(min(walls_ms), 1),
        "wall_max_ms": round(max(walls_ms), 1),
        "peak_rss_mb": round(maxrss_to_mb(peak_rss_raw), 1),
        "exit_codes": sorted(set(exits)),
        "os": platform.system(),
        "machine": platform.machine(),
    }
    if args.expect_exit is not None:
        result["exit_ok"] = all(e == args.expect_exit for e in exits)

    print(json.dumps(result))
    # human line to stderr
    flag = ""
    if args.expect_exit is not None and not result.get("exit_ok", True):
        flag = f"  [!] exits={result['exit_codes']} (expected {args.expect_exit})"
    print(
        f"  {args.label:<34} median {result['wall_median_ms']:>8.1f} ms   "
        f"min {result['wall_min_ms']:>8.1f} ms   RSS {result['peak_rss_mb']:>6.1f} MB{flag}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
