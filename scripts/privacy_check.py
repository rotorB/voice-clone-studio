#!/usr/bin/env python3
"""Fail when tracked repository data violates the publication policy."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]

AUDIO_SUFFIXES = {
    ".wav", ".wave", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus",
    ".caf", ".aif", ".aiff",
}
PRIVATE_SUFFIXES = {
    ".env", ".key", ".pem", ".p12", ".pfx", ".mobileprovision",
    ".provisionprofile", ".safetensors", ".gguf", ".ckpt", ".pt", ".pth",
    ".onnx", ".sqlite", ".sqlite3",
}
PRIVATE_PARTS = {
    "voice-library", "voice_library", "recordings", "references", "presets",
}

# Assemble sensitive markers so the checker does not flag its own source.
LITERAL_MARKERS = [
    "/" + "Users" + "/",
    "Apple" + " Development:",
    "BEGIN " + "PRIVATE KEY",
    "BEGIN RSA " + "PRIVATE KEY",
    "BEGIN OPENSSH " + "PRIVATE KEY",
]
SECRET_PATTERNS = [
    re.compile(rb"gh" + rb"[opsu]_[A-Za-z0-9]{20,}"),
    re.compile(rb"sk" + rb"-[A-Za-z0-9]{20,}"),
    re.compile(rb"hf" + rb"_[A-Za-z0-9]{20,}"),
    re.compile(rb"AKIA" + rb"[0-9A-Z]{16}"),
    re.compile(rb"xox" + rb"[baprs]-[A-Za-z0-9-]{10,}"),
]
CYRILLIC = re.compile(r"[\u0400-\u04ff]")
EMAIL = re.compile(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
EMAIL_BYTES = re.compile(rb"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def tracked_files() -> list[Path]:
    output = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [ROOT / item.decode() for item in output.split(b"\0") if item]


def commit_identities() -> list[str]:
    output = subprocess.check_output(
        ["git", "log", "--all", "--format=%an <%ae>%n%cn <%ce>"],
        cwd=ROOT,
        text=True,
    )
    return [line for line in output.splitlines() if line]


def main() -> int:
    findings: list[str] = []

    for path in tracked_files():
        # A locally deleted file can remain in the index until the change is
        # staged. It is absent from the tree that would be published.
        if not path.exists():
            continue
        relative = PurePosixPath(path.relative_to(ROOT).as_posix())
        lowered = relative.as_posix().lower()
        suffix = path.suffix.lower()

        if suffix in AUDIO_SUFFIXES or suffix in PRIVATE_SUFFIXES:
            findings.append(f"private file type is tracked: {relative}")
        if any(part.lower() in PRIVATE_PARTS for part in relative.parts):
            findings.append(f"private data directory is tracked: {relative}")
        if "preset" in path.name.lower():
            findings.append(f"preset file is tracked: {relative}")
        if lowered.startswith("output/") and relative.name != ".gitkeep":
            findings.append(f"runtime output is tracked: {relative}")

        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = ""
        for marker in LITERAL_MARKERS:
            if marker.encode().lower() in data.lower():
                findings.append(f"sensitive marker in {relative}: {marker}")
        for pattern in SECRET_PATTERNS:
            if pattern.search(data):
                findings.append(f"possible secret in {relative}: {pattern.pattern[:8]!r}…")
        for address in EMAIL_BYTES.findall(data):
            if not address.lower().endswith(b"@users.noreply.github.com"):
                findings.append(f"email address in tracked content: {relative}")
        if text and CYRILLIC.search(text):
            findings.append(f"non-English Cyrillic text in {relative}")

    for identity in commit_identities():
        addresses = EMAIL.findall(identity)
        if any(not address.lower().endswith("@users.noreply.github.com") for address in addresses):
            findings.append("non-private email found in reachable commit metadata")

    if findings:
        print("Privacy check failed:")
        for finding in sorted(set(findings)):
            print(f"- {finding}")
        return 1

    print("Privacy check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
