#!/usr/bin/env python3
"""Read raw GMII tap from FPGA; compare per-byte with pcapng reference.

Bytes [0..5]  = DST MAC captured raw from GMII (before eth_rx_mac).
Bytes [6..11] = SRC MAC.
Bytes [12..13]= EtherType.
Bytes [14..]  = payload start.

Run concurrently with the test (see Makefile tap-test target).  After
--timeout seconds of silence the serial loop exits and --pcap comparison
runs.  --fpga-mac filters UART frames: background traffic (DST far from
FPGA MAC) is shown but not matched against pcap test-frame slots.

Hardware setup:
    USB-UART adapter RX  -->  FPGA J11 uart_tap_tx_o pin
    USB-UART adapter GND -->  FPGA J11 GND
"""

import argparse
import subprocess
import sys

try:
    import serial
except ImportError:
    sys.exit("pyserial not installed: pip install pyserial")


ETHERTYPE_NAMES = {
    0x0800: "IPv4",
    0x0806: "ARP",
    0x86DD: "IPv6",
    0x8100: "VLAN",
}

_FIELD = {
    **{i: f"DST[{i}]" for i in range(6)},
    **{i: f"SRC[{i - 6}]" for i in range(6, 12)},
    12: "ETH[0]", 13: "ETH[1]",
    **{i: f"PAY[{i - 14}]" for i in range(14, 256)},
}


def fmt_mac(raw: bytes) -> str:
    return ":".join(f"{b:02x}" for b in raw)


def hamming(a: bytes, b: bytes) -> int:
    return sum(bin(x ^ y).count("1") for x, y in zip(a, b))


def read_n(ser: "serial.Serial", n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if not chunk:
            raise TimeoutError(f"Timeout after {len(buf)}/{n} bytes")
        buf += chunk
    return buf


def decode_frame(raw: bytes) -> None:
    print(f"  hex : {' '.join(f'{b:02x}' for b in raw)}")
    if len(raw) >= 6:
        print(f"  DST : {fmt_mac(raw[0:6])}")
    if len(raw) >= 12:
        print(f"  SRC : {fmt_mac(raw[6:12])}")
    if len(raw) < 14:
        return
    et = (raw[12] << 8) | raw[13]
    print(f"  ETH : 0x{et:04x}  ({ETHERTYPE_NAMES.get(et, '?')})")
    if len(raw) > 14:
        print(f"  PAY : {' '.join(f'{b:02x}' for b in raw[14:])}")


def read_pcap_unicast(pcap_path: str, n: int) -> "list[bytes]":
    """Return first n bytes of each unicast Ethernet frame in pcap (via tcpdump)."""
    try:
        result = subprocess.run(
            ["tcpdump", "-r", pcap_path, "-xx", "-n"],
            capture_output=True, text=True, timeout=10
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        print(f"  [pcap] tcpdump error: {exc}")
        return []

    frames: "list[bytes]" = []
    current: "list[int]" = []

    def flush() -> None:
        if current and not (current[0] & 0x01):  # skip multicast / broadcast
            frames.append(bytes(current[:n]))

    for line in result.stdout.splitlines():
        if not line.startswith("\t"):
            flush()
            current = []
        else:
            for tok in line.split():
                if len(tok) == 4 and all(c in "0123456789abcdefABCDEF" for c in tok):
                    current.append(int(tok[:2], 16))
                    current.append(int(tok[2:], 16))
    flush()
    return frames


def compare_frames(uart: bytes, ref: bytes) -> None:
    ref_hex = " ".join(f"{b:02x}" for b in ref)
    print(f"  REF : {ref_hex}")
    mismatches = [
        (i, uart[i], ref[i])
        for i in range(min(len(uart), len(ref)))
        if uart[i] != ref[i]
    ]
    if not mismatches:
        print("  CMP : MATCH")
        return
    for i, u, r in mismatches:
        field = _FIELD.get(i, f"[{i}]")
        print(
            f"  DIFF: {field:8s}  uart=0x{u:02x} ({u:08b}b)"
            f"  ref=0x{r:02x} ({r:08b}b)  xor=0x{u ^ r:02x} ({u ^ r:08b}b)"
        )
    print(f"  CMP : {len(mismatches)} MISMATCH(ES)")


def main() -> None:
    ap = argparse.ArgumentParser(description="FPGA raw GMII tap reader")
    ap.add_argument("--port",     default="/dev/ttyUSB0")
    ap.add_argument("--baud",     type=int, default=115200)
    ap.add_argument("--count",    type=int, default=32,
                    help="Bytes per frame (must match FPGA N_BYTES)")
    ap.add_argument("--frames",   type=int, default=8,
                    help="Frames to capture (0 = read until timeout)")
    ap.add_argument("--timeout",  type=float, default=5.0,
                    help="Serial read timeout in seconds")
    ap.add_argument("--pcap",     default=None,
                    help="Reference pcapng: compare UART bytes vs what PC sent")
    ap.add_argument("--fpga-mac", default=None,
                    help="FPGA MAC (xx:xx:xx:xx:xx:xx) to distinguish test "
                         "frames from background traffic in comparison")
    args = ap.parse_args()

    fpga_mac_bytes: "bytes | None" = None
    if args.fpga_mac:
        fpga_mac_bytes = bytes.fromhex(args.fpga_mac.replace(":", ""))

    print(f"Connecting to {args.port} @ {args.baud} baud "
          f"({args.count} bytes/frame, raw GMII tap)...")

    collected: "list[bytes]" = []
    with serial.Serial(args.port, args.baud, timeout=args.timeout) as ser:
        ser.reset_input_buffer()
        frame_num = 0
        while args.frames == 0 or frame_num < args.frames:
            print(f"\n--- Frame {frame_num + 1} ---")
            try:
                raw = read_n(ser, args.count)
            except TimeoutError as exc:
                print(f"  {exc}")
                break
            decode_frame(raw)
            collected.append(raw)
            frame_num += 1

    if not (args.pcap and collected):
        print("\nDone.")
        return

    print(f"\n{'=' * 64}")
    print("COMPARISON: UART (FPGA GMII raw) vs pcap (PC sent)")
    print(f"{'=' * 64}")
    ref_frames = read_pcap_unicast(args.pcap, args.count)
    print(f"pcap: {len(ref_frames)} frame(s)   UART: {len(collected)} frame(s)")

    ref_idx = 0
    for i, uart in enumerate(collected):
        # Classify: test frame (DST close to FPGA MAC) vs background
        is_test = True
        if fpga_mac_bytes and len(uart) >= 6:
            dist = hamming(uart[:6], fpga_mac_bytes)
            if dist > 16:  # >2 fully-wrong bytes → different frame entirely
                is_test = False

        tag = "" if is_test else "  [background]"
        print(f"\nFrame {i + 1}{tag}:")

        if not is_test:
            dst_str = fmt_mac(uart[:6]) if len(uart) >= 6 else "?"
            fpga_str = fmt_mac(fpga_mac_bytes) if fpga_mac_bytes else "?"
            print(f"  CMP : skipped (DST {dst_str} != {fpga_str})")
            continue

        if ref_idx < len(ref_frames):
            compare_frames(uart, ref_frames[ref_idx])
            ref_idx += 1
        else:
            print(f"  CMP : no pcap reference (ref exhausted at frame {ref_idx})")

    skipped = len(collected) - ref_idx - sum(
        1 for f in collected
        if fpga_mac_bytes and len(f) >= 6 and hamming(f[:6], fpga_mac_bytes) <= 16
    ) + ref_idx
    print(f"\nMatched {ref_idx}/{len(ref_frames)} pcap frame(s).")
    print("\nDone.")


if __name__ == "__main__":
    main()
