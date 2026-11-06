#!/usr/bin/env python3
"""Reject private workstation paths and credential files in the public tree/app."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ALLOWED_ROOT_FILES = {"MacWipe.swift", "Interface.swift", "build.sh", "README.md", "LICENSE", "SECURITY.md", ".gitignore"}
ALLOWED_TREES = {"Assets", "docs", "scripts", ".github"}
PATTERNS = [
    rb"/Users/[A-Za-z0-9_.-]{1,64}/", rb"/home/[A-Za-z0-9_.-]{1,64}/", rb"\x2ecodex/", rb"\x2eruntime/",
    rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    rb"(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{30,})",
]
FORBIDDEN_SUFFIXES = {".env", ".pem", ".key", ".p12", ".pfx", ".sqlite", ".db", ".mobileprovision"}


def native(command):
    if sys.platform == "darwin":
        probe = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True)
        if probe.stdout.strip() == "1":
            return ["/usr/bin/arch", "-arm64", *command]
    return command


def check_bytes(path):
    data = path.read_bytes()
    for pattern in PATTERNS:
        if re.search(pattern, data):
            raise SystemExit(f"Private path or credential pattern in {path.relative_to(ROOT)} (value redacted)")


def main():
    result = subprocess.run(native(["git", "ls-files", "-z"]), cwd=ROOT, capture_output=True, check=True)
    files = [Path(name.decode()) for name in result.stdout.split(b"\0") if name]
    if not files:
        raise SystemExit("No staged/tracked public files")
    for relative in files:
        if relative.parts[0] not in ALLOWED_TREES and str(relative) not in ALLOWED_ROOT_FILES:
            raise SystemExit(f"Unapproved public path: {relative}")
        if relative.suffix.lower() in FORBIDDEN_SUFFIXES or relative.name.startswith(".env"):
            raise SystemExit(f"Credential/data file: {relative}")
        path = ROOT / relative
        if path.is_symlink():
            raise SystemExit(f"Unexpected source symlink: {relative}")
        check_bytes(path)
    app = ROOT / "build/Протереть Mac.app"
    for path in app.rglob("*"):
        if path.is_file():
            check_bytes(path)
    subprocess.run(native(["codesign", "--verify", "--deep", "--strict", str(app)]), check=True)
    arches = subprocess.check_output(native(["lipo", "-archs", str(app / "Contents/MacOS/MacWipe")]), text=True).split()
    if set(arches) != {"arm64", "x86_64"}:
        raise SystemExit("The release must include arm64 and x86_64")
    print(f"PASS: {len(files)} public source files; universal app; no private-path/credential matches")


if __name__ == "__main__":
    main()
