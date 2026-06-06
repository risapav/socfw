#!/usr/bin/env python3
"""
UDP echo test for eth_test_04 FPGA.

Sends N UDP packets to FPGA_IP:FPGA_PORT and verifies each reply.
Port 7 is the RFC 862 echo service port (mirrored by udp_echo.sv).

Exit code: 0 = all PASS, 1 = any FAIL.
"""

import argparse
import socket
import sys
import time


def run(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(args.timeout)
    if args.bind_ip:
        s.bind((args.bind_ip, 0))

    passed = 0
    failed = 0

    for i in range(args.count):
        msg = f"UDP echo test packet {i:04d} [{args.count}]".encode()
        if args.payload_bytes:
            msg = msg[:args.payload_bytes].ljust(args.payload_bytes, b"\xA5")

        try:
            s.sendto(msg, (args.ip, args.port))
            data, addr = s.recvfrom(4096)
            if data == msg:
                if args.verbose:
                    print(f"  [{i+1:3d}/{args.count}] PASS  {len(data):4d}B  from {addr[0]}:{addr[1]}")
                passed += 1
            else:
                snippet = repr(data[:32])
                print(f"  [{i+1:3d}/{args.count}] FAIL  got {snippet}...")
                failed += 1
        except socket.timeout:
            print(f"  [{i+1:3d}/{args.count}] FAIL  timeout ({args.timeout}s)")
            failed += 1

        if args.delay > 0:
            time.sleep(args.delay)

    s.close()

    print(f"\nResult: {passed}/{args.count} PASS  ({failed} FAIL)")
    return 0 if failed == 0 else 1


def main():
    p = argparse.ArgumentParser(description="UDP echo test for eth_test_04 FPGA")
    p.add_argument("--ip",           default="192.168.0.2", help="FPGA IP address")
    p.add_argument("--port",   "-p", default=7,    type=int, help="UDP echo port (default 7)")
    p.add_argument("--count",  "-n", default=10,   type=int, help="Number of packets")
    p.add_argument("--timeout","-t", default=1.0,  type=float, help="Per-packet timeout seconds")
    p.add_argument("--delay",  "-d", default=0.0,  type=float, help="Delay between packets")
    p.add_argument("--payload-bytes", "-s", default=0, type=int, help="Fixed payload size (0=auto)")
    p.add_argument("--bind-ip",       default="", help="Source IP to bind to")
    p.add_argument("--verbose", "-v", action="store_true", help="Print each packet result")
    args = p.parse_args()

    print(f"UDP echo test: {args.ip}:{args.port}  count={args.count}  timeout={args.timeout}s")
    sys.exit(run(args))


if __name__ == "__main__":
    main()
