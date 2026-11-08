"""Download the small Lean Kernel Arena bundle, with bounded safe extraction."""
import argparse
import hashlib
from pathlib import Path
import tarfile
import urllib.request

URL = "https://arena.lean-lang.org/lean-arena-tests.tar.gz"
PINNED_SHA256 = "aff129ed66c22a2befd3ffc2ce02dc61cc84cec096bc977d46dc885638468797"
parser = argparse.ArgumentParser()
parser.add_argument("--latest", action="store_true", help="Allow a newer upstream bundle")
parser.add_argument("--destination", type=Path, default=Path("arena"))
args = parser.parse_args()
archive = Path(".tools/arena-tests.tar.gz")
archive.parent.mkdir(exist_ok=True)
if not archive.exists():
    urllib.request.urlretrieve(URL, archive)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != PINNED_SHA256 and not args.latest:
    raise SystemExit(f"Bundle changed: {digest}. Review it, or pass --latest explicitly.")
root = args.destination.resolve()
root.mkdir(parents=True, exist_ok=True)
count = 0
with tarfile.open(archive, "r:gz") as bundle:
    for member in bundle:
        if not member.isfile() or not member.name.endswith(".ndjson"):
            continue
        relative = Path(member.name)
        target = (root / relative).resolve()
        if not target.is_relative_to(root) or relative.parts[0] not in {"good", "bad"}:
            raise SystemExit(f"Unsafe archive path: {member.name}")
        if member.size > 11 * 1024 * 1024:
            raise SystemExit(f"Unexpected large fixture: {member.name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        source = bundle.extractfile(member)
        assert source is not None
        with source, target.open("wb") as output:
            while chunk := source.read(1024 * 1024):
                output.write(chunk)
        count += 1
print(f"Extracted {count} fixtures; SHA-256 {digest}")
