"""Alternate complete checker processes on identical inputs; no accepted-proof cache.

Requires psutil. Hashing and export generation are outside the measured interval.
The report includes every run, exit status, output, and peak-memory measurement.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time

import psutil
from report_paths import report_path


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def measure(command):
    peak = 0
    cpu_seconds = None
    cpu_user_seconds = None
    cpu_kernel_seconds = None
    stopped = threading.Event()
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def sample():
        nonlocal peak
        try:
            monitored = psutil.Process(process.pid)
            while not stopped.is_set():
                memory = monitored.memory_info()
                peak = max(peak, getattr(memory, "peak_wset", memory.rss))
                stopped.wait(0.002)
        except psutil.NoSuchProcess:
            pass

    monitor = threading.Thread(target=sample, daemon=True)
    monitor.start()
    stdout, stderr = process.communicate()
    elapsed = time.perf_counter() - started
    stopped.set()
    monitor.join()
    if platform.system() == "Windows":
        class Counters(ctypes.Structure):
            _fields_ = [("cb", ctypes.c_ulong), ("faults", ctypes.c_ulong)] + [
                (name, ctypes.c_size_t) for name in (
                    "peak", "working", "peak_paged", "paged", "peak_nonpaged",
                    "nonpaged", "pagefile", "peak_pagefile")]

        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        query = ctypes.WinDLL("psapi").GetProcessMemoryInfo
        query.argtypes = [ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong]
        query.restype = ctypes.c_int
        if query(int(process._handle), ctypes.byref(counters), counters.cb):
            peak = max(peak, counters.peak)
        timestamps = [ctypes.c_ulonglong() for _ in range(4)]
        cpu_query = ctypes.WinDLL("kernel32").GetProcessTimes
        cpu_query.argtypes = [ctypes.c_void_p] + [ctypes.POINTER(ctypes.c_ulonglong)] * 4
        cpu_query.restype = ctypes.c_int
        if cpu_query(int(process._handle), *(ctypes.byref(value) for value in timestamps)):
            cpu_kernel_seconds = timestamps[2].value / 10_000_000
            cpu_user_seconds = timestamps[3].value / 10_000_000
            cpu_seconds = cpu_kernel_seconds + cpu_user_seconds
    return dict(seconds=elapsed, cpu_seconds=cpu_seconds, cpu_user_seconds=cpu_user_seconds,
                cpu_kernel_seconds=cpu_kernel_seconds, peak_resident_bytes=peak, exit_code=process.returncode,
                stdout=stdout.decode("utf-8", errors="replace"),
                stderr=stderr.decode("utf-8", errors="replace"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--zig", type=Path, default=Path("zig-out/bin/ziglean.exe"))
    parser.add_argument("--nano", type=Path, default=Path(".upstream/nano-lean/target/release/nl-fast.exe"))
    parser.add_argument("--threads", type=int, nargs="+", default=[8, 16])
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=4096)
    parser.add_argument("--profile", action="store_true", help="Include ziglean's batch timings")
    parser.add_argument("--max-steps", type=int, default=100_000_000)
    parser.add_argument("--max-temporary-nodes", type=int, default=64_000_000)
    parser.add_argument("--report", type=Path, default=Path("reports/comparison.json"))
    args = parser.parse_args()
    if args.repeat < 1 or any(count < 1 or count > 32 for count in args.threads):
        parser.error("Positive repeats and 1..32 workers are required")
    result = dict(recorded_at_utc=datetime.now(timezone.utc).isoformat(), platform=platform.platform(), processor=platform.processor(),
                  memory_measurement="OS peak working set" if platform.system() == "Windows" else "2ms sampled RSS",
                  executables={name: dict(path=report_path(path), sha256=digest(path))
                               for name, path in [("ziglean", args.zig), ("nano-lean", args.nano)]},
                  source_sha256={path.as_posix(): digest(path) for path in
                                 sorted([*Path("src").glob("*.zig"), Path("build.zig"), Path("test.zig")])},
                  cases=[])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    failed = False
    for path in args.inputs:
        input_hash = digest(path)
        for threads in args.threads:
            commands = {
                "ziglean": [str(args.zig.resolve()), "-j", str(threads), "--batch-size", str(args.batch_size),
                            "--max-steps", str(args.max_steps), "--max-temporary-nodes", str(args.max_temporary_nodes), str(path)],
                "nano-lean": [str(args.nano.resolve()), "--no-cache", "-j", str(threads), "--steps", str(args.max_steps), str(path)],
            }
            if args.profile:
                commands["ziglean"].insert(1, "--profile")
            case = dict(input=report_path(path), input_sha256=input_hash, input_bytes=path.stat().st_size,
                        threads=threads, batch_size=args.batch_size, runs=[])
            for iteration in range(args.repeat):
                order = ["ziglean", "nano-lean"] if iteration % 2 == 0 else ["nano-lean", "ziglean"]
                for checker in order:
                    run = measure(commands[checker])
                    run.update(checker=checker, iteration=iteration,
                               command=[report_path(Path(commands[checker][0])), *commands[checker][1:-1], report_path(path)])
                    case["runs"].append(run)
                    failed |= run["exit_code"] != 0
                    print(f'{report_path(path)} j={threads} {checker}: {run["seconds"]:.4f}s, '
                          f'{run["peak_resident_bytes"] / 2**20:.1f} MiB, exit {run["exit_code"]}', flush=True)
                    if run["exit_code"]:
                        print(run["stderr"][-1000:].encode("ascii", "backslashreplace").decode(), flush=True)
            case["summary"] = {
                checker: dict(median_seconds=statistics.median(run["seconds"] for run in case["runs"] if run["checker"] == checker)
                              if all(run["exit_code"] == 0 for run in case["runs"] if run["checker"] == checker) else None,
                              successful_runs=sum(run["exit_code"] == 0 for run in case["runs"] if run["checker"] == checker),
                              peak_resident_bytes=max(run["peak_resident_bytes"] for run in case["runs"] if run["checker"] == checker))
                for checker in commands}
            result["cases"].append(case)
            args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(int(failed))


if __name__ == "__main__":
    main()
