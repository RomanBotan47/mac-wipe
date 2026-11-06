#!/usr/bin/env python3
"""Run headless safety checks; only isolated test processes are terminated."""
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "build/Протереть Mac.app/Contents/MacOS/MacWipe"
CASES = [
    ("absolute deadline", "--guard-test-parent", "1", -signal.SIGTERM, 1.7, 6),
    ("heartbeat lost", "--guard-test-parent", "12", -signal.SIGTERM, 3.8, 8),
    ("SIGTERM fallback", "--guard-test-ignore-term", "1", -signal.SIGKILL, 2.2, 7),
    ("normal cleanup", "--guard-test-cleanup", "12", 0, 0.9, 6),
]


def verify(case):
    name, mode, timeout, expected, minimum, maximum = case
    start = time.monotonic()
    result = subprocess.run([str(BINARY), mode, timeout], timeout=12, capture_output=True, text=True)
    elapsed = time.monotonic() - start
    if result.returncode != expected or not minimum <= elapsed <= maximum:
        raise RuntimeError(f"{name}: exit={result.returncode}, elapsed={elapsed:.2f}s")
    return f"PASS {name}: {elapsed:.2f}s"


if __name__ == "__main__":
    subprocess.run([str(BINARY), "--self-test"], check=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for line in pool.map(verify, CASES):
            print(line)
    for parent, timeout in [("1", "5"), (str(os.getpid()), "nan"), (str(os.getpid()), "902")]:
        result = subprocess.run([str(BINARY), "--guard", parent, timeout], timeout=3, capture_output=True)
        if result.returncode != 64:
            raise RuntimeError("Guard accepted an invalid parent/deadline")
    print("PASS: guard rejects unrelated parent, non-finite time, and excessive deadline")
