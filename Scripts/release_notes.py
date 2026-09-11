#!/usr/bin/env python3
"""Extract one user-facing version section for the release draft."""
import re
import sys
from pathlib import Path


def release_notes(version: str, changelog: str) -> str:
    match = re.search(r"^## " + re.escape(version) + r"(?: — [^\n]+)?\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
    if not match or not match[1].strip():
        raise ValueError(f"No changelog section for {version}")
    return match[1].strip() + "\n"


if __name__ == "__main__":
    print(release_notes(sys.argv[1], Path(sys.argv[2]).read_text()), end="")
