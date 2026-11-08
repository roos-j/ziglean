"""Portable paths for published reports, without local directory identities."""
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent


def report_path(path: Path) -> str:
    """Use a repository-relative path, or only the filename for external inputs."""
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPOSITORY_ROOT).as_posix()
    except ValueError:
        return resolved.name
