#!/usr/bin/env python3
"""UART loopback hardware test for uart_test_04.

Sends bytes over UART and verifies they echo back identically.
FPGA must be programmed with uart_test_04 bitfile (16x oversampled RX, FIFO loopback).

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


def flush_residual(ser):
    """Drain any leftover bytes from a previous failed transfer."""
    ser.timeout = 0.1
    drained = ser.read(256)
    ser.timeout = 2.0
    return len(drained)


def loopback_bulk(ser, data, label, verbose, chunksize=None):
    """Send data in chunks and collect echoed bytes.

    Returns (fails, received_list).

    chunksize=None (default): single bulk write of entire payload.
    chunksize=N: split into N-byte writes with read after each chunk.
      chunksize=1 reproduces the uart_test_02 sequential mode.
      chunksize=64 exercises FIFO boundaries.
    """
    if chunksize is None:
        chunksize = len(data)

    received = []
    offset = 0
    chunk_idx = 0
    while offset < len(data):
        chunk = data[offset:offset + chunksize]
        ser.write(bytes(chunk))
        got = ser.read(len(chunk))
        received.extend(got)
        if len(got) < len(chunk):
            missing = len(chunk) - len(got)
            print(f"  WARN {label}: timeout chunk[{chunk_idx}] offset={offset}, "
                  f"missing {missing} bytes")
            received.extend([None] * missing)
        offset += chunksize
        chunk_idx += 1

    # Check for extra bytes in RX buffer (stream drift)
    drained = flush_residual(ser)
    if drained:
        print(f"  WARN {label}: {drained} residual byte(s) drained after receive")

    fails = 0
    for i, (s, g) in enumerate(zip(data, received)):
        chunk_of = i // chunksize
        pos_in_chunk = i % chunksize
        is_last = (pos_in_chunk == min(chunksize, len(data) - chunk_of * chunksize) - 1)
        ctx = f"chunk[{chunk_of}] pos={pos_in_chunk}{'(LAST)' if is_last else ''}"

        prev_s = f"0x{data[i-1]:02X}" if i > 0 else "---"
        next_s = f"0x{data[i+1]:02X}" if i < len(data) - 1 else "---"

        if g is None:
            print(f"  FAIL [{i:3d}] {ctx}  sent=0x{s:02X}  got=MISSING  "
                  f"prev={prev_s} next={next_s}")
            fails += 1
        elif s != g:
            print(f"  FAIL [{i:3d}] {ctx}  sent=0x{s:02X}  got=0x{g:02X}  "
                  f"prev={prev_s} next={next_s}")
            fails += 1
        elif verbose:
            print(f"  PASS [{i:3d}] {ctx}  sent=0x{s:02X}  got=0x{g:02X}")

    return fails


def run_suite(ser, args, chunksize, run_idx):
    """Run T1+T2+T3 once with the given chunksize.  Returns total fails."""
    cs_label = f"cs={chunksize}" if chunksize else "cs=bulk"
    label = f"run{run_idx} {cs_label}"

    random.seed(args.seed)

    fails = 0

    f = loopback_bulk(ser, [0x55], f"{label} T1", args.verbose, chunksize)
    if f:
        print(f"  FAIL {label} T1 single byte 0x55: {f} wrong")
    fails += f

    pattern = [0x00, 0xFF, 0xAA, 0x55, 0x81, 0x7E, 0x01, 0xFE]
    f = loopback_bulk(ser, pattern, f"{label} T2", args.verbose, chunksize)
    if f:
        print(f"  FAIL {label} T2 pattern {len(pattern)}B: {f} wrong")
    fails += f

    payload = [random.randint(0, 255) for _ in range(args.count)]
    f = loopback_bulk(ser, payload, f"{label} T3", args.verbose, chunksize)
    if f:
        print(f"  FAIL {label} T3 random {args.count}B: {f} wrong")
    fails += f

    status = "PASS" if fails == 0 else "FAIL"
    print(f"{status} {label}: {fails} byte(s) wrong")
    return fails


def main():
    ap = argparse.ArgumentParser(description="uart_test_04 HW loopback test")
    ap.add_argument("--port",    default="/dev/ttyUSB0", help="Serial port")
    ap.add_argument("--baud",    type=int, default=115200)
    ap.add_argument("--count",   type=int, default=256,
                    help="Random bytes in T3 (default 256)")
    ap.add_argument("--seed",    type=int, default=42)
    ap.add_argument("--chunksize", type=int, default=None,
                    help="Bytes per write (None=full bulk, 1=sequential)")
    ap.add_argument("--repeat",  type=int, default=1,
                    help="Repeat the full test suite N times (default 1)")
    ap.add_argument("--sweep-chunks", metavar="LIST",
                    help="Comma-separated chunk sizes to sweep, e.g. 1,8,16,24,25,26,32. "
                         "Overrides --chunksize and --repeat runs each size.")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    print(f"uart_test_04 HW loopback -- {args.port} @ {args.baud} 8N1")
    print(f"  FIFO depth: 64 bytes  seed={args.seed}  count={args.count}")
    print()

    ser = open_port(args.port, args.baud)

    total_fails = 0

    if args.sweep_chunks:
        sizes = []
        for tok in args.sweep_chunks.split(","):
            tok = tok.strip()
            if tok:
                sizes.append(int(tok))
        repeat = args.repeat if args.repeat > 1 else 1
        for cs in sizes:
            cs_fails = 0
            for r in range(repeat):
                cs_fails += run_suite(ser, args, cs, r + 1)
            pf = "PASS" if cs_fails == 0 else "FAIL"
            print(f"  --> {pf} sweep cs={cs}: {cs_fails} total fails over {repeat} run(s)")
            print()
            total_fails += cs_fails
    else:
        cs = args.chunksize
        for r in range(args.repeat):
            total_fails += run_suite(ser, args, cs, r + 1)

    ser.close()
    print()
    if total_fails == 0:
        print("PASS uart_test_04 HW loopback: all tests passed")
        sys.exit(0)
    else:
        print(f"FAIL uart_test_04 HW loopback: {total_fails} byte(s) wrong")
        sys.exit(1)


if __name__ == "__main__":
    main()
