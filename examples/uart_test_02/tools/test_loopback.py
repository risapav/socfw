#!/usr/bin/env python3
"""UART loopback hardware test for uart_test_02.

Sends bytes over UART and verifies they echo back identically.
FPGA must be programmed with uart_test_02 bitfile.

Tests:
  T1  Single byte: 0x55
  T2  Pattern burst: 0x00, 0xFF, 0xAA, 0x55, 0x81, 0x7E, 0x01, 0xFE
  T3  Random bytes  (--count, default 64)
"""

import argparse
import random
import sys
import time

try:
    import serial
except ImportError:
    print("FAIL: pyserial not installed  (pip install pyserial)")
    sys.exit(1)


def open_port(port, baud):
    try:
        ser = serial.Serial(port, baud, bytesize=8, parity="N", stopbits=1,
                            timeout=2.0)
    except serial.SerialException as e:
        print(f"FAIL open {port}: {e}")
        sys.exit(1)
    ser.reset_input_buffer()
    ser.reset_output_buffer()
    time.sleep(0.05)
    return ser


def loopback(ser, data, label, verbose):
    """Bulk send + receive — fast, for small payloads (<=8 bytes)."""
    ser.write(bytes(data))
    received = ser.read(len(data))
    fails = 0
    for i, (s, g) in enumerate(zip(data, received)):
        if s == g:
            if verbose:
                print(f"  PASS [{i:3d}] sent=0x{s:02X} got=0x{g:02X}")
        else:
            print(f"  FAIL [{i:3d}] sent=0x{s:02X} got=0x{g:02X}")
            fails += 1
    if len(received) < len(data):
        missing = len(data) - len(received)
        print(f"  FAIL {label}: timeout, missing {missing} bytes")
        fails += missing
    return fails


def loopback_sequential(ser, data, label, verbose):
    """Send one byte at a time, read echo before sending next.

    Required for the FPGA's 1-byte loopback buffer — bulk writes overflow it.
    """
    fails = 0
    for i, s in enumerate(data):
        ser.write(bytes([s]))
        got_bytes = ser.read(1)
        if not got_bytes:
            print(f"  FAIL [{i:3d}] sent=0x{s:02X} got=TIMEOUT")
            fails += 1
        else:
            g = got_bytes[0]
            if s == g:
                if verbose:
                    print(f"  PASS [{i:3d}] sent=0x{s:02X} got=0x{g:02X}")
            else:
                print(f"  FAIL [{i:3d}] sent=0x{s:02X} got=0x{g:02X}")
                fails += 1
    return fails


def chk(fails, label):
    if fails == 0:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}: {fails} byte(s) wrong")
    return fails


def main():
    ap = argparse.ArgumentParser(description="uart_test_02 HW loopback test")
    ap.add_argument("--port",    default="/dev/ttyUSB0", help="Serial port")
    ap.add_argument("--baud",    type=int, default=115200)
    ap.add_argument("--count",   type=int, default=64,
                    help="Number of random bytes in T3")
    ap.add_argument("--seed",    type=int, default=42)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    random.seed(args.seed)

    print(f"uart_test_02 HW loopback -- {args.port} @ {args.baud} 8N1")
    print()

    ser = open_port(args.port, args.baud)
    total_fails = 0

    # T1: single byte
    total_fails += chk(loopback(ser, [0x55], "T1", args.verbose),
                       "T1 single byte 0x55")

    # T2: fixed pattern
    pattern = [0x00, 0xFF, 0xAA, 0x55, 0x81, 0x7E, 0x01, 0xFE]
    total_fails += chk(loopback(ser, pattern, "T2", args.verbose),
                       f"T2 pattern burst {len(pattern)} bytes")

    # T3: random bytes — sequential (1-byte FPGA loopback buffer)
    payload = [random.randint(0, 255) for _ in range(args.count)]
    total_fails += chk(loopback_sequential(ser, payload, "T3", args.verbose),
                       f"T3 random {args.count} bytes (seed={args.seed})")

    ser.close()
    print()
    if total_fails == 0:
        print("PASS uart_test_02 HW loopback: all tests passed")
        sys.exit(0)
    else:
        print(f"FAIL uart_test_02 HW loopback: {total_fails} byte(s) wrong")
        sys.exit(1)


if __name__ == "__main__":
    main()
