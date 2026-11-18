#!/usr/bin/env python3
"""Compare complete HTTP servers with hey over loopback."""
import argparse
import http.client
import os
from pathlib import Path
import random
import re
import select
import shlex
import signal
import statistics
import subprocess
import sys


WORKLOADS = {
    "baseline": ("GET", "/baseline11?a=13&b=42", None, b"55"),
    "post": ("POST", "/baseline11?a=13&b=42", b"20", b"75"),
    "json": ("GET", "/json", None, b'{"message":"Hello, World!"}'),
}


def verify(port, workload):
    method, path, body, expected = WORKLOADS[workload]
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        for _ in range(2):
            connection.request(method, path, body=body)
            response = connection.getresponse()
            if response.status != 200 or response.read() != expected or response.will_close:
                raise RuntimeError("server did not produce the expected keep-alive response")
        if workload == "post":
            connection.request(method, path, body=iter((b"2", b"0")), encode_chunked=True)
            response = connection.getresponse()
            if response.status != 200 or response.read() != expected:
                raise RuntimeError("server did not handle a chunked POST")
    finally:
        connection.close()


def load(port, args, count):
    method, path, body, _ = WORKLOADS[args.workload]
    command = ["hey", "-n", str(count), "-c", str(args.connections), "-cpus", str(args.client_cpus),
               "-m", method, "-t", "5", "-disable-compression", "-disable-redirects"]
    if body is not None:
        command += ["-d", body.decode(), "-T", "text/plain"]
    command += [f"http://127.0.0.1:{port}{path}"]
    result = subprocess.run(command, text=True, capture_output=True, check=True, timeout=120)
    status = re.findall(r"^\s*\[(\d+)\]\s+(\d+) responses", result.stdout, re.M)
    if status != [("200", str(count))] or "Error distribution:" in result.stdout:
        raise RuntimeError(f"load did not complete with exactly {count} OK responses:\n{result.stdout}")
    rate = re.search(r"Requests/sec:\s+([0-9.]+)", result.stdout)
    p99 = re.search(r"^\s*99%{1,2} in ([0-9.]+) secs", result.stdout, re.M)
    if rate is None or p99 is None:
        raise RuntimeError(f"could not read hey metrics:\n{result.stdout}")
    return float(rate[1]), float(p99[1]) * 1000


def run(command, args):
    read_fd, write_fd = os.pipe()
    pid = None
    try:
        argv = [*command, "serve", "0", str(args.workers)]
        pid = os.posix_spawnp(argv[0], argv, os.environ,
                              file_actions=[(os.POSIX_SPAWN_DUP2, write_fd, 1)])
    finally:
        os.close(write_fd)
        if pid is None:
            os.close(read_fd)
    try:
        if not select.select([read_fd], [], [], 10)[0]:
            raise RuntimeError(f"{command[0]} did not announce a port")
        port = int(os.read(read_fd, 64).strip())
        verify(port, args.workload)
        load(port, args, max(args.connections, 2_000 // args.connections * args.connections))
        rate, p99 = load(port, args, args.requests)
    finally:
        os.close(read_fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, _, usage = os.wait4(pid, 0)
    rss = usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    return rate, p99, rss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workload", choices=WORKLOADS, default="baseline")
    parser.add_argument("--connections", type=int, default=8)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--client-cpus", type=int, default=2)
    parser.add_argument("--requests", type=int, default=100_000)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--reference", help="optional command accepting 'serve PORT WORKERS' and printing its port")
    args = parser.parse_args()
    if (not 1 <= args.connections <= args.workers <= 64 or args.requests < args.connections
            or args.requests % args.connections or args.runs < 1 or args.client_cpus < 1):
        parser.error("use 1–64 workers, at most one connection per worker, a divisible request count, and positive runs and client CPUs")
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        parser.error("peak RSS units are supported on macOS and Linux")
    variants = [
        (name, [str(Path("zig-out/bin", binary).resolve())])
        for name, binary in (("plain Zig", "http-bench-zig"), ("zrx", "http-bench"))
    ]
    if args.reference:
        command = shlex.split(args.reference)
        if not command:
            parser.error("--reference must contain a command")
        variants.append(("reference", command))
    samples = {name: [] for name, _ in variants}
    rng = random.Random(0)
    for _ in range(args.runs):
        rng.shuffle(variants)
        for name, command in variants:
            try:
                samples[name].append(run(command, args))
            except Exception as error:
                raise RuntimeError(f"{name} failed the {args.workload} trial") from error
    print(f"{args.workload}: {args.requests:,} OK responses per trial, {args.runs} runs, "
          f"{args.connections} keep-alive connections, {args.workers} server workers")
    for name, rows in samples.items():
        rate, p99, rss = zip(*rows)
        print(f"{name:10} median {statistics.median(rate):,.0f} req/s "
              f"({min(rate):,.0f}–{max(rate):,.0f}), median p99 {statistics.median(p99):.2f} ms, "
              f"max peak RSS {max(rss) / 2**20:.2f} MiB")


if __name__ == "__main__":
    main()
