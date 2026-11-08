"""Use Zig as nano-lean's Windows GNU C compiler and archiver."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

zig = os.environ.get("ZIG") or shutil.which("zig")
if zig is None:
    local = Path(__file__).resolve().parents[1] / ".tools/zigpy/ziglang/zig.exe"
    if local.is_file():
        zig = str(local)
if zig is None:
    raise SystemExit("Put Zig 0.14.1 on PATH or set ZIG to its executable.")

arguments = sys.argv[1:]
if arguments and arguments[0] == "--ar":
    command = [zig, "ar", *arguments[1:]]
else:
    arguments = [argument for argument in arguments if not argument.startswith("--target=")]
    command = [zig, "cc", "-target", "x86_64-windows-gnu", *arguments]
raise SystemExit(subprocess.call(command))
