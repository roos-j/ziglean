"""Run one checker invocation and record wall time and peak resident memory.

Requires psutil. Does not download data or repeat the check. On Windows it reads
the OS peak working-set counter; other platforms report the sampled maximum RSS.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import time

import psutil
from report_paths import report_path

parser = argparse.ArgumentParser()
parser.add_argument("input", type=Path)
parser.add_argument("--exe", type=Path, default=Path("zig-out/bin/ziglean.exe"))
parser.add_argument("--report", type=Path, default=Path("reports/benchmark.json"))
parser.add_argument("--max-steps", type=int, default=100_000_000)
parser.add_argument("--max-temporary-nodes", type=int, default=64_000_000)
parser.add_argument("--threads", type=int, default=1)
parser.add_argument("--batch-size", type=int, default=8192)
args = parser.parse_args()
args.report.parent.mkdir(parents=True, exist_ok=True)
log_path = args.report.with_suffix(".log")
digest = hashlib.sha256()
with args.input.open("rb") as source:
    metadata = json.loads(source.readline())
    source.seek(0)
    for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
        digest.update(block)
command = [str(args.exe.resolve()), "--progress", "-j", str(args.threads), "--batch-size", str(args.batch_size), "--max-steps", str(args.max_steps),
           "--max-temporary-nodes", str(args.max_temporary_nodes), str(args.input)]
started = time.monotonic()
peak = 0
with log_path.open("w", encoding="utf-8") as log:
    process = subprocess.Popen(command, stdout=log, stderr=log)
    monitored = psutil.Process(process.pid)
    while process.poll() is None:
        try:
            memory = monitored.memory_info()
            peak = max(peak, getattr(memory, "peak_wset", memory.rss))
        except psutil.NoSuchProcess:
            break
        time.sleep(0.05)
    exit_code = process.wait()
reported_command = [report_path(args.exe), *command[1:-1], report_path(args.input)]
result = dict(command=reported_command, exit_code=exit_code, seconds=time.monotonic() - started,
              peak_resident_bytes=peak, memory_measurement="OS peak working set" if platform.system() == "Windows" else "50ms sampled RSS",
              input_bytes=args.input.stat().st_size, input_sha256=digest.hexdigest(),
              executable_sha256=hashlib.sha256(args.exe.read_bytes()).hexdigest(),
              platform=platform.platform(), processor=platform.processor(), metadata=metadata,
              log=log_path.read_text(encoding="utf-8"))
args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, indent=2), flush=True)
raise SystemExit(exit_code)
