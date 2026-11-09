"""Compare two ziglean executables with alternating, complete-process runs.

Requires psutil. Input hashing is outside timing and warms the filesystem cache.
Optional warmup runs warm executable/input state before measured comparisons;
they are recorded separately, and measured outliers are never filtered.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import zipfile

from compare import digest, measure
from report_paths import report_path


def numeric_option(command, option):
    """Report the effective value when an experiment overrides a CLI option."""
    result = None
    for index, argument in enumerate(command[:-1]):
        if argument == option:
            try:
                result = int(command[index + 1])
            except ValueError:
                result = None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", type=Path, default=Path("zig-out/bin/ziglean.exe"))
    parser.add_argument("--baseline-arg", action="append", default=[],
                        help="Additional baseline argument; use --baseline-arg=--flag")
    parser.add_argument("--candidate-arg", action="append", default=[],
                        help="Additional candidate argument; use --candidate-arg=--flag")
    parser.add_argument("--threads", type=int, nargs="+", default=[16])
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=0,
                        help="Unmeasured runs per variant and case before comparison (default: 0)")
    parser.add_argument("--batch-size", type=int, default=4096)
    parser.add_argument("--max-steps", type=int, default=1_000_000_000)
    parser.add_argument("--max-temporary-nodes", type=int, default=64_000_000)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--source-snapshot", type=Path,
                        help="Candidate source ZIP, for measurements while the working tree advances")
    parser.add_argument("--report", type=Path, default=Path("reports/versions.json"))
    args = parser.parse_args()
    if args.repeat < 1 or any(count < 1 or count > 32 for count in args.threads):
        parser.error("Positive repeats and 1..32 workers are required")
    if args.warmup < 0:
        parser.error("Warmup count must be nonnegative")
    executables = {"baseline": args.baseline, "candidate": args.candidate}
    if args.source_snapshot:
        with zipfile.ZipFile(args.source_snapshot) as snapshot:
            source_hashes = {name: hashlib.sha256(snapshot.read(name)).hexdigest()
                             for name in sorted(snapshot.namelist()) if name.endswith(".zig")}
    else:
        source_hashes = {path.as_posix(): digest(path) for path in
                         sorted([*Path("src").glob("*.zig"), *Path("tests").rglob("*.zig"),
                                 Path("build.zig"), Path("test.zig")])}
    result = {
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "processor": platform.processor(),
        "memory_measurement": "OS peak working set" if platform.system() == "Windows" else "2ms sampled RSS",
        "executables": {label: {"path": report_path(path), "sha256": digest(path)}
                        for label, path in executables.items()},
        "source_sha256": source_hashes,
        "cases": [],
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    failed = False
    for path in args.inputs:
        input_hash = digest(path)
        for threads in args.threads:
            case = {"input": report_path(path), "input_sha256": input_hash,
                    "input_bytes": path.stat().st_size, "threads": threads,
                    "batch_size": args.batch_size, "runs": []}

            def run_variant(label, iteration, *, warmup=False):
                command = [str(executables[label].resolve()), "-j", str(threads),
                           "--batch-size", str(args.batch_size), "--max-steps", str(args.max_steps),
                           "--max-temporary-nodes", str(args.max_temporary_nodes)]
                if args.profile:
                    command.append("--profile")
                command.extend(args.baseline_arg if label == "baseline" else args.candidate_arg)
                command.append(str(path))
                run = measure(command)
                run.update(variant=label, iteration=iteration,
                           threads=numeric_option(command, "-j"),
                           batch_size=numeric_option(command, "--batch-size"),
                           command=[report_path(executables[label]), *command[1:-1], report_path(path)])
                phase = "warmup " if warmup else ""
                print(f'{report_path(path)} j={run["threads"]} {phase}{label}: {run["seconds"]:.4f}s, '
                      f'{run["peak_resident_bytes"] / 2**20:.1f} MiB, exit {run["exit_code"]}', flush=True)
                if run["exit_code"]:
                    print(run["stderr"][-1500:].encode("ascii", "backslashreplace").decode(), flush=True)
                return run

            def run_phase(count, output, *, warmup=False):
                succeeded = True
                for iteration in range(count):
                    labels = list(executables)
                    if iteration % 2:
                        labels.reverse()
                    for label in labels:
                        run = run_variant(label, iteration, warmup=warmup)
                        output.append(run)
                        succeeded &= run["exit_code"] == 0
                return succeeded

            warmup_ok = True
            if args.warmup:
                case["warmup"] = args.warmup
                case["warmup_runs"] = []
                warmup_ok = run_phase(args.warmup, case["warmup_runs"], warmup=True)
                case["warmup_succeeded"] = warmup_ok
                failed |= not warmup_ok
            if warmup_ok:
                failed |= not run_phase(args.repeat, case["runs"])
            else:
                print(f'{report_path(path)} j={threads}: skipping measurements after failed warmup', flush=True)
            case["summary"] = {}
            case["configurations"] = {}
            for label in executables:
                runs = [run for run in case["runs"] if run["variant"] == label]
                settings = runs or [run for run in case["warmup_runs"] if run["variant"] == label]
                succeeded = bool(runs) and all(run["exit_code"] == 0 for run in runs)
                case["configurations"][label] = {
                    "threads": settings[0]["threads"], "batch_size": settings[0]["batch_size"]}
                case["summary"][label] = {
                    "median_seconds": statistics.median(run["seconds"] for run in runs)
                    if succeeded else None,
                    "peak_resident_bytes": max((run["peak_resident_bytes"] for run in runs), default=None),
                    "median_cpu_seconds": statistics.median(run["cpu_seconds"] for run in runs)
                    if succeeded and all(run["cpu_seconds"] is not None for run in runs) else None,
                    "successful_runs": sum(run["exit_code"] == 0 for run in runs),
                }
            result["cases"].append(case)
            args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(int(failed))


if __name__ == "__main__":
    main()
