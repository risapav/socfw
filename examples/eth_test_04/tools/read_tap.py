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
    if et != 0x0800 or len(raw) < 20:
        return
    # IPv4 header starts at byte 14
    ihl = (raw[14] & 0x0F) * 4
    ip_total = (raw[16] << 8) | raw[17] if len(raw) >= 18 else None
    proto = raw[23] if len(raw) > 23 else None
    src_ip = raw[26:30] if len(raw) >= 30 else None
    dst_ip = raw[30:34] if len(raw) >= 34 else None
    print(f"  IHL : {ihl} bytes, proto={proto}, ip_total={ip_total}")
    if src_ip:
        print(f"  SIP : {fmt_ip(src_ip)}")
    if dst_ip:
        print(f"  DIP : {fmt_ip(dst_ip)}")
    if proto == 17:  # UDP
        udp_off = 14 + ihl  # typically 34 for standard IPv4
        if len(raw) >= udp_off + 8:
            sp  = (raw[udp_off]     << 8) | raw[udp_off + 1]
            dp  = (raw[udp_off + 2] << 8) | raw[udp_off + 3]
            ulen = (raw[udp_off + 4] << 8) | raw[udp_off + 5]
            ucsum = (raw[udp_off + 6] << 8) | raw[udp_off + 7]
            payload_len = ulen - 8
            print(f"  UDP : sport={sp}, dport={dp}, len={ulen} (payload={payload_len}), csum=0x{ucsum:04x}")
            print(f"  RAW-UDP-LEN bytes: {raw[udp_off+4]:02x} {raw[udp_off+5]:02x}  -> {ulen}")
        elif len(raw) >= udp_off:
            print(f"  UDP : partial ({len(raw) - udp_off} bytes of header)")


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
