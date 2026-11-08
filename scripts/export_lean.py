"""Export declarations using an existing Lean project, without copying its build cache."""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("project", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("module")
parser.add_argument("declarations", nargs="*")
parser.add_argument("--exporter", type=Path, default=Path(".upstream/export/.lake/build/bin/lean4export.exe"))
args = parser.parse_args()
project = args.project.resolve()
paths = [project / ".lake/build/lib/lean"]
paths += sorted((project / ".lake/packages").glob("*/.lake/build/lib/lean"))
# Compiled roots must precede sources: a root-level Foo.lean can otherwise
# shadow .lake/build/lib/lean/Foo.olean when importing the top-level module.
paths.append(project)
environment = os.environ.copy()
toolchain_name = (project / "lean-toolchain").read_text().strip().replace("/", "--").replace(":", "---")
toolchain = Path.home() / ".elan/toolchains" / toolchain_name
environment["LEAN_SYSROOT"] = str(toolchain)
environment["PATH"] = str(toolchain / "bin") + os.pathsep + environment.get("PATH", "")
environment["LEAN_PATH"] = os.pathsep.join(str(path) for path in paths)
args.output.parent.mkdir(parents=True, exist_ok=True)
command = [str(args.exporter.resolve()), args.module]
if args.declarations:
    command += ["--", *args.declarations]
with args.output.open("wb") as output:
    result = subprocess.run(command, env=environment, stdout=output)
if result.returncode:
    with args.output.open("rb") as output:
        print(output.read(2000).decode("utf-8", errors="replace"))
    args.output.unlink(missing_ok=True)
raise SystemExit(result.returncode)
