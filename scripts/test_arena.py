"""Run fast correctness fixtures, optionally including the compact stress suite."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from report_paths import report_path

parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, default=Path("arena"))
parser.add_argument("--exe", default="zig-out/bin/ziglean.exe")
parser.add_argument("--filter", default="")
parser.add_argument("--threads", type=int, default=1)
parser.add_argument("--stress", action="store_true", help="Include perf/ fixtures")
parser.add_argument("--timeout", type=float, help="Seconds per case (120, or 390 with --stress)")
parser.add_argument("--max-steps", type=int, help="Steps per declaration (100 million, or 1 billion with --stress)")
parser.add_argument("--max-temporary-nodes", type=int, help="Temporary nodes per declaration (64 million, or 128 million with --stress)")
parser.add_argument("--max-bytes", type=int, default=11 * 1024 * 1024)
parser.add_argument("--report", type=Path, default=Path("reports/arena.json"))
args = parser.parse_args()
timeout = args.timeout if args.timeout is not None else (390 if args.stress else 120)
max_steps = args.max_steps if args.max_steps is not None else (1_000_000_000 if args.stress else 100_000_000)
max_temporary_nodes = args.max_temporary_nodes if args.max_temporary_nodes is not None else (128_000_000 if args.stress else 64_000_000)
results = []
started = time.monotonic()
for outcome, expected in [("good", 0), ("bad", 1)]:
    for path in sorted((args.root / outcome).rglob("*.ndjson")):
        if args.filter not in str(path) or path.stat().st_size > args.max_bytes:
            continue
        if not args.stress and "perf" in path.parts:
            continue
        before = time.monotonic()
        try:
            result = subprocess.run([args.exe, "-j", str(args.threads), "--max-steps", str(max_steps),
                                     "--max-temporary-nodes", str(max_temporary_nodes), str(path)], capture_output=True, timeout=timeout)
            actual = result.returncode
            message = result.stderr.decode("utf-8", errors="replace").strip()
        except subprocess.TimeoutExpired:
            actual, message = -1, "timeout"
        passed = actual == expected
        results.append(dict(file=report_path(path), expected=expected, actual=actual, ok=passed,
                            seconds=time.monotonic() - before, message=message,
                            threads=args.threads, max_steps=max_steps, max_temporary_nodes=max_temporary_nodes, timeout=timeout))
        if not passed:
            print(f"FAIL {report_path(path)}: exit {actual}: {message[:600]}", flush=True)
if not results:
    raise SystemExit("No fixtures selected. Run scripts/fetch_arena.py first.")
print(f'{sum(result["ok"] for result in results)}/{len(results)} passed in {time.monotonic() - started:.2f}s')
args.report.parent.mkdir(parents=True, exist_ok=True)
args.report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
raise SystemExit(any(not result["ok"] for result in results))
