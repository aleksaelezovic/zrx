#!/usr/bin/env python3
"""Compare complete HTTP servers over loopback, with hey or http-bench-load."""
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
    finally:
        connection.close()


def pipelined(port, args, count):
    _, path, _, expected = WORKLOADS[args.workload]
    batches = max(1, count // (args.connections * args.pipeline))
    command = [str(Path("zig-out/bin/http-bench-load").resolve()), str(port), str(args.connections),
               str(args.pipeline), str(batches), path, expected.decode()]
    result = subprocess.run(command, text=True, capture_output=True, timeout=300)
    if result.returncode != 0:
        raise RuntimeError(f"pipelined load failed:\n{result.stderr}")
    rate, p99 = result.stdout.split()
    return float(rate), float(p99)


def load(port, args, count):
    if args.pipeline:
        return pipelined(port, args, count)
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
        argv = [*command, "serve", "0"]
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
        load(port, args, warm_up(args))
        rate, p99 = load(port, args, args.requests)
    finally:
        os.close(read_fd)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, _, usage = os.wait4(pid, 0)
    rss = usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    # The whole life of the server: the trial, and the short warm-up before it.
    return rate, p99, rss, usage.ru_utime + usage.ru_stime


def warm_up(args):
    per_round = args.connections * max(1, args.pipeline)
    return max(per_round, 2_000 // per_round * per_round)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workload", choices=WORKLOADS, default="baseline")
    parser.add_argument("--connections", type=int, default=8)
    parser.add_argument("--client-cpus", type=int, default=2)
    parser.add_argument("--requests", type=int, default=100_000)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--pipeline", type=int, default=0,
                        help="send this many requests per write with http-bench-load instead of hey")
    parser.add_argument("--reference", action="append", default=[], metavar="NAME=COMMAND",
                        help="another server to compare: a command accepting 'serve PORT' and printing its port; repeatable")
    args = parser.parse_args()
    if (args.connections < 1 or args.requests < args.connections
            or args.requests % args.connections or args.runs < 1 or args.client_cpus < 1):
        parser.error("use at least one connection, a divisible request count, and positive runs and client CPUs")
    if args.pipeline < 0 or args.pipeline and (args.workload == "post" or args.requests % (args.connections * args.pipeline)):
        parser.error("--pipeline takes the baseline or json workload and a request count divisible by connections times depth")
    if sys.platform != "darwin" and not sys.platform.startswith("linux"):
        parser.error("peak RSS units are supported on macOS and Linux")
    variants = [
        (name, [str(Path("zig-out/bin", binary).resolve())])
        for name, binary in (("plain Zig", "http-bench-zig"), ("zrx", "http-bench"))
    ]
    for reference in args.reference:
        name, separator, command = reference.partition("=")
        if not separator or not name or "/" in name or " " in name:
            name, command = "reference", reference
        if not shlex.split(command):
            parser.error("--reference must contain a command")
        variants.append((name, shlex.split(command)))
    names = [name for name, _ in variants]
    repeated = sorted({name for name in names if names.count(name) > 1})
    if repeated:
        # Samples are kept by name: two servers under one name would be reported as one.
        parser.error(f"every server needs a name of its own; given more than once: {', '.join(repeated)}")
    samples = {name: [] for name, _ in variants}
    rng = random.Random(0)
    for _ in range(args.runs):
        rng.shuffle(variants)
        for name, command in variants:
            try:
                samples[name].append(run(command, args))
            except Exception as error:
                raise RuntimeError(f"{name} failed the {args.workload} trial") from error
    sent = f", {args.pipeline} per write" if args.pipeline else ""
    print(f"{args.workload}: {args.requests:,} OK responses per trial, {args.runs} runs, "
          f"{args.connections} keep-alive connections{sent}")
    # The CPU time is that of the server's whole life, so both figures below
    # are taken over everything it served: the warm-up and the trial. The
    # cores are an estimate, which takes the warm-up to have run at the
    # trial's rate.
    served = args.requests + warm_up(args)
    what = "batch" if args.pipeline > 1 else "request"
    for name, rows in sorted(samples.items(), key=lambda entry: -statistics.median(row[0] for row in entry[1])):
        rate, p99, rss, cpu = zip(*rows)
        seconds = statistics.median(cpu)
        print(f"{name:10} median {statistics.median(rate):>9,.0f} req/s "
              f"({min(rate):,.0f}–{max(rate):,.0f}), p99 per {what} {statistics.median(p99):.2f} ms, "
              f"CPU {seconds / served * 1e6:.1f} µs/request "
              f"({seconds * statistics.median(rate) / served:.1f} cores), "
              f"max peak RSS {max(rss) / 2**20:.1f} MiB")

if __name__ == "__main__":
    main()
