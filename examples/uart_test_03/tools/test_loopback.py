#!/usr/bin/env python3
"""UART loopback hardware test for uart_test_03.

Sends bytes over UART and verifies they echo back identically.
FPGA must be programmed with uart_test_03 bitfile.

Improvement over uart_test_02: bulk writes work without sequential workaround
because the FPGA now has a 64-byte RX/TX FIFO.

Tests:
  T1  Single byte: 0x55
  T2  Pattern burst: 8 fixed bytes (bulk)
  T3  Bulk random bytes (--count, default 256)
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


def loopback_bulk(ser, data, label, verbose):
    """Bulk send + bulk receive.

    Works correctly with uart_test_03 because the FPGA has a 64-byte FIFO
    that absorbs the burst and echoes at line rate.
    """
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


def chk(fails, label):
    if fails == 0:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}: {fails} byte(s) wrong")
    return fails


def main():
    ap = argparse.ArgumentParser(description="uart_test_03 HW loopback test")
    ap.add_argument("--port",    default="/dev/ttyUSB0", help="Serial port")
    ap.add_argument("--baud",    type=int, default=115200)
    ap.add_argument("--count",   type=int, default=256,
                    help="Number of random bytes in T3 (default 256)")
    ap.add_argument("--seed",    type=int, default=42)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    random.seed(args.seed)

    print(f"uart_test_03 HW loopback -- {args.port} @ {args.baud} 8N1")
    print(f"  FIFO depth: 64 bytes -- bulk writes supported")
    print()

    ser = open_port(args.port, args.baud)
    total_fails = 0

    # T1: single byte
    total_fails += chk(loopback_bulk(ser, [0x55], "T1", args.verbose),
                       "T1 single byte 0x55")

    # T2: fixed pattern (bulk)
    pattern = [0x00, 0xFF, 0xAA, 0x55, 0x81, 0x7E, 0x01, 0xFE]
    total_fails += chk(loopback_bulk(ser, pattern, "T2", args.verbose),
                       f"T2 pattern burst {len(pattern)} bytes")

    # T3: random bytes bulk (no sequential workaround needed)
    payload = [random.randint(0, 255) for _ in range(args.count)]
    total_fails += chk(loopback_bulk(ser, payload, "T3", args.verbose),
                       f"T3 random {args.count} bytes bulk (seed={args.seed})")

    ser.close()
    print()
    if total_fails == 0:
        print("PASS uart_test_03 HW loopback: all tests passed")
        sys.exit(0)
    else:
        print(f"FAIL uart_test_03 HW loopback: {total_fails} byte(s) wrong")
        sys.exit(1)


if __name__ == "__main__":
    main()
