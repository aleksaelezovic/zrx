#!/usr/bin/env python3
"""Repeat complete audit CLI runs and check the published archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import sys
import tempfile
import time


def fixtures(path, count):
    expected = hashlib.sha256()
    with path.open("wb") as source:
        for index in range(count):
            record = dict(id=index, ts_ms=index * 10, action="update", resource="node-7")
            expected.update((json.dumps(record, separators=(",", ":")) + "\n").encode())
            record.update(actor="operator", detail="x" * 160)
            source.write((json.dumps(record, separators=(",", ":")) + "\n").encode())
    return expected.digest()


def run(exe, flags, source, output, expected):
    before = time.perf_counter()
    pid = os.posix_spawn(exe, [exe, *flags, source, output], os.environ)
    _, status, usage = os.wait4(pid, 0)
    seconds = time.perf_counter() - before
    if status:
        raise RuntimeError(f"{exe} exited {os.waitstatus_to_exitcode(status)}")
    with Path(output).open("rb") as archive:
        if hashlib.file_digest(archive, "sha256").digest() != expected:
            raise RuntimeError(f"{exe} published different bytes")
    Path(output).unlink()
    rss = usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    return seconds, rss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=int, default=300_000)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--work-dir", type=Path, help="parent directory for temporary files")
    args = parser.parse_args()
    if not (args.records > 0 and args.runs > 0):
        parser.error("--records and --runs must be positive")
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        parser.error("peak RSS units are supported on macOS and Linux")
    variants = [
        (f"{impl}/{mode}", str(Path("zig-out/bin", binary).resolve()), flags)
        for impl, binary in (("plain", "audit-archive-zig"), ("zrx", "audit-archive"))
        for mode, flags in (("sync", ["--sync"]), ("queued", []))
    ]
    with tempfile.TemporaryDirectory(prefix="audit-compare-", dir=args.work_dir) as tmp:
        source, output = map(str, (Path(tmp, "input.jsonl"), Path(tmp, "archive.jsonl")))
        expected = fixtures(Path(source), args.records)
        for _, exe, flags in variants:
            run(exe, flags, source, output, expected)
        samples = {name: [] for name, _, _ in variants}
        rng = random.Random(0)
        for _ in range(args.runs):
            rng.shuffle(variants)
            for name, exe, flags in variants:
                samples[name].append(run(exe, flags, source, output, expected))
        print(f"{args.records:,} records, {os.stat(source).st_size:,} input bytes, "
              f"{args.runs} runs per variant, matching SHA-256 {expected.hex()}")
        print("variant          median s   range s       records/s   max peak RSS")
        for name, runs in samples.items():
            elapsed, rss = zip(*runs)
            median = statistics.median(elapsed)
            print(f"{name:15} {median:8.3f}   {min(elapsed):.3f}–{max(elapsed):.3f}"
                  f"   {args.records / median:10,.0f}   {max(rss) / 2**20:7.2f} MiB")


if __name__ == "__main__":
    main()
