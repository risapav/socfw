#!/usr/bin/env python3
"""
UDP echo test for eth_udp_echo_test FPGA peripheral.

Tests the UDP echo path: send payload, expect identical payload back.
Measures per-packet round-trip latency and reports success/failure stats.

Usage:
    python3 udp_echo_test.py --host 192.168.1.50 --count 100 --size 32
    python3 udp_echo_test.py --host 192.168.1.50 --sweep   # payload size sweep
"""
import argparse
import socket
import struct
import sys
import time


def run_echo_test(host: str, port: int, count: int, size: int,
                  timeout: float = 1.0, verbose: bool = False) -> tuple[int, int]:
    """Send `count` UDP echo packets of `size` bytes. Returns (ok, fail)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)

    ok = 0
    fail = 0

    for i in range(count):
        payload = bytes([(i + j) & 0xFF for j in range(size)])
        t0 = time.monotonic()
        try:
            sock.sendto(payload, (host, port))
            data, addr = sock.recvfrom(65535)
            dt_ms = (time.monotonic() - t0) * 1000

            if data == payload:
                ok += 1
                if verbose:
                    print(f"  OK  [{i:4d}] {len(data):5d} B  {dt_ms:7.2f} ms  from {addr}")
            else:
                fail += 1
                print(f"  BAD [{i:4d}] got {len(data)} B, expected {len(payload)} B")
        except socket.timeout:
            fail += 1
            print(f"  TMO [{i:4d}] timeout after {timeout:.1f} s")

    sock.close()
    return ok, fail


def run_sweep(host: str, port: int, count: int, timeout: float) -> None:
    """Test a range of payload sizes."""
    sizes = [1, 4, 8, 16, 32, 64, 128, 256, 384, 508]  # stay under MAX_PAYLOAD_BYTES=512
    print(f"{'Size':>6}  {'OK':>6}  {'Fail':>6}  {'Pass%':>7}")
    print("-" * 35)
    for size in sizes:
        ok, fail = run_echo_test(host, port, count, size, timeout)
        pct = 100.0 * ok / (ok + fail) if (ok + fail) > 0 else 0.0
        status = "OK" if fail == 0 else "FAIL"
        print(f"{size:>6}  {ok:>6}  {fail:>6}  {pct:>6.1f}%  {status}")


def main() -> None:
    ap = argparse.ArgumentParser(description="UDP echo test for FPGA eth_udp_echo_test")
    ap.add_argument("--host",    default="192.168.1.50", help="FPGA IP address")
    ap.add_argument("--port",    type=int, default=50000, help="UDP echo port")
    ap.add_argument("--count",   type=int, default=100,   help="Number of packets per run")
    ap.add_argument("--size",    type=int, default=32,    help="Payload size in bytes")
    ap.add_argument("--timeout", type=float, default=1.0, help="Per-packet timeout (s)")
    ap.add_argument("--sweep",   action="store_true",     help="Run payload size sweep")
    ap.add_argument("--verbose", action="store_true",     help="Print per-packet results")
    args = ap.parse_args()

    if args.sweep:
        print(f"=== UDP echo sweep: {args.host}:{args.port}, {args.count} packets/size ===")
        run_sweep(args.host, args.port, args.count, args.timeout)
        return

    print(f"=== UDP echo test: {args.host}:{args.port}, {args.count} x {args.size} B ===")
    ok, fail = run_echo_test(
        args.host, args.port, args.count, args.size,
        timeout=args.timeout, verbose=args.verbose,
    )
    total = ok + fail
    pct = 100.0 * ok / total if total > 0 else 0.0
    print(f"\nRESULT: ok={ok} fail={fail} ({pct:.1f}% success)")
    sys.exit(0 if fail == 0 else 1)


if __name__ == "__main__":
    main()
