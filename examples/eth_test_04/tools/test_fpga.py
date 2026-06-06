#!/usr/bin/env python3
"""
UDP echo test for eth_test_04 FPGA.
Sends UDP datagrams and verifies the FPGA echoes them back unchanged.

Usage:
  python3 test_fpga.py [--ip IP] [--port PORT] [--timeout SEC] [--iface IF]
"""

import argparse
import socket
import subprocess
import sys
import time

FPGA_IP      = "192.168.0.2"
FPGA_MAC     = "00:0a:35:01:fe:c0"
FPGA_PORT    = 8080
PC_IFACE     = "enp0s31f6"
TIMEOUT_SEC  = 1.0

def arp_setup(ip, mac, iface):
    r = subprocess.run(
        ["sudo", "ip", "neigh", "replace", ip, "lladdr", mac, "nud", "permanent",
         "dev", iface],
        capture_output=True, text=True
    )
    if r.returncode != 0:
        print(f"  [!] ARP setup failed: {r.stderr.strip()}")
    else:
        print(f"  ARP: {ip} -> {mac} on {iface}")

def udp_echo(sock, payload: bytes, ip: str, port: int, timeout: float) -> bytes | None:
    sock.sendto(payload, (ip, port))
    sock.settimeout(timeout)
    try:
        data, _ = sock.recvfrom(65535)
        return data
    except socket.timeout:
        return None

def run_test(sock, label: str, payload: bytes, ip: str, port: int, timeout: float) -> bool:
    resp = udp_echo(sock, payload, ip, port, timeout)
    if resp is None:
        print(f"  FAIL  {label!r:<22}  no response (timeout {timeout:.1f}s)")
        return False
    if resp == payload:
        print(f"  PASS  {label!r:<22}  {len(payload)}B echoed correctly")
        return True
    print(f"  FAIL  {label!r:<22}  echo mismatch")
    print(f"        sent: {payload[:32].hex()}")
    print(f"        got:  {resp[:32].hex()}")
    return False

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ip",      default=FPGA_IP)
    p.add_argument("--port",    default=FPGA_PORT, type=int)
    p.add_argument("--timeout", default=TIMEOUT_SEC, type=float)
    p.add_argument("--iface",   default=PC_IFACE)
    p.add_argument("--mac",     default=FPGA_MAC)
    p.add_argument("--no-arp",  action="store_true", help="skip static ARP setup")
    args = p.parse_args()

    print(f"eth_test_04 UDP echo test  ->  {args.ip}:{args.port}")
    print(f"Interface: {args.iface}  timeout: {args.timeout}s")
    print()

    if not args.no_arp:
        arp_setup(args.ip, args.mac, args.iface)
        print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Bind to a fixed local port so FPGA always echoes back here.
    sock.bind(("", 0))
    local_port = sock.getsockname()[1]
    print(f"Local UDP port: {local_port}")
    print()

    tests = [
        ("2B minimal",       b"HI"),
        ("5B ascii",         b"HELLO"),
        ("16B hex",          b"0123456789ABCDEF"),
        ("64B boundary",     b"X" * 64),
        ("100B medium",      bytes(range(100))),
        ("1472B max-udp",    bytes(i & 0xFF for i in range(1472))),
    ]

    passed = 0
    for label, payload in tests:
        ok = run_test(sock, label, payload, args.ip, args.port, args.timeout)
        if ok:
            passed += 1
        time.sleep(0.05)

    sock.close()

    print()
    total = len(tests)
    print(f"Result: {passed}/{total} PASS")
    sys.exit(0 if passed == total else 1)

if __name__ == "__main__":
    main()
