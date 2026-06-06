#!/usr/bin/env python3
"""Read UART stream tap from FPGA and display raw Ethernet frame header bytes.

The FPGA sends the first CAPTURE_BYTES (default 20) bytes of each received
Ethernet frame via UART 8N1 at 115200 baud on J11 connector pin 0 (M2).

Hardware setup:
    USB-UART adapter RX  -->  FPGA J11 pin 0 (M2, PMOD pin 10)
    USB-UART adapter GND -->  FPGA J11 GND

Usage:
    python3 tools/read_tap.py [--port /dev/ttyUSB0] [--baud 115200]
                              [--count 20] [--frames 8]
"""

import argparse
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


def fmt_mac(raw: bytes) -> str:
    return ":".join(f"{b:02x}" for b in raw)


def fmt_ip(raw: bytes) -> str:
    return ".".join(str(b) for b in raw)


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
    name = ETHERTYPE_NAMES.get(et, "?")
    print(f"  ETH : 0x{et:04x}  ({name})")
    if len(raw) >= 15:
        status  = raw[14]
        fcs_ok  = bool(status & 0x01)
        mac_ok  = bool(status & 0x02)
        ok_flag = "OK" if (fcs_ok and mac_ok) else "FAIL"
        print(f"  STA : fcs_ok={int(fcs_ok)}  mac_ok={int(mac_ok)}  [{ok_flag}]  raw=0x{status:02x}")


def main() -> None:
    ap = argparse.ArgumentParser(description="FPGA UART stream tap reader")
    ap.add_argument("--port",   default="/dev/ttyUSB0")
    ap.add_argument("--baud",   type=int, default=115200)
    ap.add_argument("--count",  type=int, default=20,
                    help="Bytes per frame (must match FPGA CAPTURE_BYTES)")
    ap.add_argument("--frames", type=int, default=8,
                    help="Number of frames to capture (0 = infinite)")
    args = ap.parse_args()

    print(f"Connecting to {args.port} @ {args.baud} baud "
          f"({args.count} bytes/frame)...")

    with serial.Serial(args.port, args.baud, timeout=5) as ser:
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
            frame_num += 1

    print("\nDone.")


if __name__ == "__main__":
    main()
