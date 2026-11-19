#!/usr/bin/env python3
"""Compare both 1BRC CLIs and optionally an external reference on the same input."""
import argparse
from contextlib import chdir
import hashlib
import os
from pathlib import Path
import random
import shlex
import statistics
import sys
import tempfile
import time


def generate(path, rows):
    rng = random.Random(2024)
    block_rows = min(rows, 100_000)
    values = []
    for _ in range(block_rows):
        value = rng.randrange(-999, 1000)
        sign = "-" if value < 0 else ""
        whole, fraction = divmod(abs(value), 10)
        values.append(f"S{rng.randrange(300):03d};{sign}{whole}.{fraction}\n".encode())
    block = b"".join(values)
    full, partial = divmod(rows, block_rows)
    with path.open("xb") as output:
        for _ in range(full):
            output.write(block)
        output.write(b"".join(values[:partial]))


def run(command, cwd):
    with tempfile.TemporaryFile() as output:
        before = time.perf_counter()
        with chdir(cwd):
            pid = os.posix_spawnp(command[0], command, os.environ,
                                  file_actions=[(os.POSIX_SPAWN_DUP2, output.fileno(), 1)])
        _, status, usage = os.wait4(pid, 0)
        seconds = time.perf_counter() - before
        if status:
            raise RuntimeError(f"{command[0]} exited {os.waitstatus_to_exitcode(status)}")
        output.seek(0)
        digest = hashlib.file_digest(output, "sha256").hexdigest()
    rss = usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    return seconds, rss, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path, help="use an existing measurements file")
    parser.add_argument("--rows", type=int, default=10_000_000, help="generate this many rows when no file is given")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--work-dir", type=Path, help="parent directory for benchmark files")
    parser.add_argument("--reference", help="reference command with absolute paths; input is ./measurements.txt")
    args = parser.parse_args()
    if args.runs < 1 or args.rows < 1:
        parser.error("--rows and --runs must be positive")
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        parser.error("peak RSS units are supported on macOS and Linux")

    comparisons = [
        (mode, [str(Path("zig-out/bin", exe).resolve()), "measurements.txt"])
        for mode, exe in (("plain Zig", "one-billion-rows-zig"), ("zrx", "one-billion-rows"))
    ]
    if args.reference:
        reference = shlex.split(args.reference)
        if not reference:
            parser.error("--reference must contain a command")
        comparisons.append(("reference", reference))
    with tempfile.TemporaryDirectory(prefix="1brc-compare-", dir=args.work_dir) as cwd:
        input_path = Path(cwd, "measurements.txt")
        if args.input:
            input_path.symlink_to(args.input.resolve(strict=True))
        else:
            generate(input_path, args.rows)
        print(f"{input_path.stat().st_size:,} input bytes, {args.runs} measured runs", flush=True)
        rng = random.Random(0)
        samples = {name: [] for name, _ in comparisons}
        expected = None
        for attempt in range(args.runs + 1):
            rng.shuffle(comparisons)
            for name, command in comparisons:
                elapsed, rss, digest = run(command, cwd)
                if expected is None:
                    expected = digest
                if expected != digest:
                    raise RuntimeError(f"{name} produced a different output checksum")
                if attempt:
                    samples[name].append((elapsed, rss))
        print(f"matching SHA-256 {expected}")
        for name, runs in samples.items():
            elapsed, rss = zip(*runs)
            print(f"{name:10} median {statistics.median(elapsed):.3f}s "
                  f"({min(elapsed):.3f}–{max(elapsed):.3f}s), max peak RSS {max(rss) / 2**20:.2f} MiB")


if __name__ == "__main__":
    main()
