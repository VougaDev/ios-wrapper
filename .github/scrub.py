#!/usr/bin/env python3
"""Fails when a tracked text file names what runs behind the apps (a web framework, its libraries, servers, internal
service names) or a path on a developer's machine. The words are kept as SHA-256 digests, so this file names none of
them, and a hit is reported by file and line only: the CI log is public too.

Usage: .github/scrub.py [file ...]   (default: every file git tracks)
"""

import hashlib
import re
import subprocess
import sys

# Digests (first 16 hex digits) of banned words, found anywhere in a line, lowercased (`xyz_language`, `XyzApp`).
ANY_CASE = {
    "18f5d48482daa90e", "230b241304054184", "372789891fee629d", "43806ca9e4e01456", "4c9fbba3a133490c",
    "5be1ecc7935f1dd8", "672106167c943018", "6cc0679757e6f714", "7281ac5300c2836c", "7d8a0838ce8e19b2",
    "858bd5f51000cf27", "a478b4566be5cb00", "a942b37ccfaf5a81", "b87aa5270772708a", "bab9d6737501f7a2",
    "ddc5177b9204093a",
}
LENGTHS = (4, 5, 6, 7, 8, 10, 19, 20)
# Internal service names, compared exactly as whole words (the same letters in another case are ordinary words).
EXACT = {"0694b4c15e7b0354", "28dd75abd5cc4fc0", "48db9125ac8b4c70", "f21b512930058aa7"}
PATHS = re.compile(r"/home/[a-z]|/Users/[A-Za-z]|[A-Z]:\\Users\\")
WORD = re.compile(r"[A-Za-z0-9_]+")  # an identifier holding the letters (`X_FLOW`) is not the name


def digest(word: str) -> str:
    return hashlib.sha256(word.encode()).hexdigest()[:16]


def hits(text: str):
    for number, line in enumerate(text.splitlines(), 1):
        low = line.lower()
        named = any(digest(low[i:i + n]) in ANY_CASE for n in LENGTHS for i in range(len(low) - n + 1))
        if named or PATHS.search(line) or any(digest(w) in EXACT for w in WORD.findall(line)):
            yield number


def main(files: list[str]) -> int:
    files = files or subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    found = 0
    for name in files:
        try:
            with open(name, encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
            continue
        for number in hits(text):
            print(f"{name}:{number}: names the backend or a developer's machine")
            found += 1
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
