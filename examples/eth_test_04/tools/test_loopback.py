#!/usr/bin/env python3
"""
Ethernet loopback test for eth_test_04 FPGA (clean MAC architecture).

The FPGA runs: eth_rx_mac -> async FIFOs (CDC) -> eth_echo_app -> eth_tx_mac.
eth_echo_app swaps MACs: echo dst = original src (PC_MAC), echo src = FPGA_MAC.

Detection: a 4-byte MAGIC marker + 2-byte sequence number is embedded in the
payload.  In 'clean' mode the marker must appear at exact offset 14 (right
after the 14-byte Ethernet header the TX MAC regenerates).

Modes (--mode):
  clean (default): offset must be 14; recv_src must be FPGA_MAC; recv_dst
                   must be PC_MAC.  This is the correct echo behavior.
  raw:   legacy byte-for-byte loopback; offset 14 or 15 accepted; src check
         is informational only.

PACKET_OUTGOING filter: recvfrom() addr[2] == 4 means the frame was captured
on the TX path (our own sent frame).  These are skipped.

Requires: CAP_NET_RAW.
  sudo python3 test_loopback.py
  OR: sudo setcap cap_net_raw+eip $(which python3)

Options:
  --iface       network interface (default enp0s31f6)
  --fpga-mac    FPGA MAC address
  --mode        'clean' or 'raw' (default: clean)
  --timeout     per-frame echo timeout in seconds (default 2.0)
  --delay       inter-frame pause in seconds (default 0.02)
  --count       repetitions per test case (default 1)
  --broadcast   use FF:FF:FF:FF:FF:FF as DST (echo dst returns as PC_MAC)
  --sniff       sniff mode: capture and print all raw frames (no transmit)
"""
import argparse
import fcntl
import socket
import struct
import sys
import time

FPGA_MAC_STR  = "00:0a:35:01:fe:c0"
PC_IFACE      = "enp0s31f6"
ETHERTYPE     = 0x9000                 # IEEE 802.3 Annex E loopback EtherType
MAGIC         = b'\xCA\xFE\xF0\x0D'   # 4-byte unique marker; marker+seq = 6 B
TIMEOUT_SEC   = 2.0
PACKET_OUTGOING = 4                    # pkttype from recvfrom() addr tuple


def mac_to_bytes(s: str) -> bytes:
    return bytes(int(x, 16) for x in s.split(':'))


def mac_to_str(b: bytes) -> str:
    return ':'.join(f'{x:02x}' for x in b)


def get_iface_mac(iface: str) -> bytes:
    SIOCGIFHWADDR = 0x8927
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        info = fcntl.ioctl(s.fileno(), SIOCGIFHWADDR,
                           struct.pack('256s', iface[:15].encode()))
    return bytes(info[18:24])


def open_sock(iface: str) -> socket.socket:
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                         socket.htons(0x0003))  # ETH_P_ALL
    sock.bind((iface, 0))
    return sock


def build_frame(dst: bytes, src: bytes, seq: int, body: bytes) -> bytes:
    """Ethernet frame: DST(6) SRC(6) ETHERTYPE(2) MAGIC(4) SEQ(2) BODY..."""
    marker  = MAGIC + struct.pack('>H', seq)
    eth_hdr = dst + src + struct.pack('>H', ETHERTYPE)
    payload = marker + body
    frame   = eth_hdr + payload
    if len(frame) < 60:
        frame += b'\x00' * (60 - len(frame))
    return frame


def loopback_once(sock: socket.socket, seq: int, body: bytes,
                  dst: bytes, src: bytes, timeout: float):
    """
    Send one frame; scan all incoming non-outgoing frames for MAGIC+SEQ.
    Returns (found: bool, byte_offset: int | None, recv_body: bytes | None,
             recv_dst: bytes | None, recv_src: bytes | None).
    """
    frame  = build_frame(dst, src, seq, body)
    marker = MAGIC + struct.pack('>H', seq)
    sock.send(frame)

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        rem = deadline - time.monotonic()
        if rem <= 0:
            break
        sock.settimeout(rem)
        try:
            data, addr = sock.recvfrom(4096)
        except socket.timeout:
            break

        # addr = (ifname, proto, pkttype, hatype, hwaddr)
        if addr[2] == PACKET_OUTGOING:
            continue

        idx = data.find(marker)
        if idx < 0:
            continue

        recv_dst  = data[0:6]  if len(data) >= 6  else None
        recv_src  = data[6:12] if len(data) >= 12 else None
        recv_body = data[idx + 6:]
        return True, idx, recv_body, recv_dst, recv_src

    return False, None, None, None, None


def run_tests(args) -> bool:
    fpga_mac = mac_to_bytes(args.fpga_mac)
    try:
        pc_mac = get_iface_mac(args.iface)
    except OSError as e:
        print(f"[ERR] Cannot get MAC for '{args.iface}': {e}")
        sys.exit(1)

    bcast_mac = b'\xff' * 6
    dst_mac   = bcast_mac if args.broadcast else fpga_mac
    dst_str   = "ff:ff:ff:ff:ff:ff" if args.broadcast else args.fpga_mac

    print(f"eth_test_04  Ethernet loopback test  [mode={args.mode}]")
    print(f"  iface     : {args.iface}  ({mac_to_str(pc_mac)})")
    print(f"  DST MAC   : {dst_str}{'  (broadcast)' if args.broadcast else ''}")
    print(f"  FPGA MAC  : {args.fpga_mac}")
    print(f"  EtherType : 0x{ETHERTYPE:04X}")
    print(f"  timeout   : {args.timeout:.1f}s / frame")
    if args.mode == "clean":
        print("  checks    : offset==14, recv_src==FPGA_MAC, recv_dst==PC_MAC")
    print()

    try:
        sock = open_sock(args.iface)
    except PermissionError:
        print("[ERR] Needs CAP_NET_RAW -- run with:  sudo python3 test_loopback.py")
        sys.exit(1)

    # (label, payload body appended after the 6-byte marker)
    tests = [
        ("min-pad  60B frame",     b'\xAB' * 36),
        ("64B  data",              bytes(range(64))),
        ("128B data",              bytes(range(128))),
        ("256B data",              bytes(i & 0xFF for i in range(256))),
        ("512B data",              bytes(i & 0xFF for i in range(512))),
        ("1000B data",             bytes(i & 0xFF for i in range(1000))),
        ("1492B data  (near max)", bytes(i & 0xFF for i in range(1492))),
        ("all-0x00  200B",         b'\x00' * 200),
        ("all-0xFF  200B",         b'\xFF' * 200),
        ("alternating  200B",      bytes([0x55, 0xAA] * 100)),
    ]

    passed  = 0
    total   = 0
    seq     = 1
    offsets = {}

    for label, body in tests:
        for rep in range(args.count):
            total += 1
            rep_sfx = f" #{rep+1}" if args.count > 1 else ""
            lbl = f"{label}{rep_sfx}"

            frame_len = len(build_frame(dst_mac, pc_mac, seq, body))
            ok, offset, recv_body, recv_dst, recv_src = loopback_once(
                sock, seq, body, dst_mac, pc_mac, args.timeout)

            if ok:
                offsets[offset] = offsets.get(offset, 0) + 1

                # Offset note
                if offset == 14:
                    offset_note = "offset=14 OK"
                elif offset == 15:
                    offset_note = "offset=15 +SFD"
                else:
                    offset_note = f"offset={offset} unexpected"

                # Body check
                expected = body
                actual   = recv_body[:len(expected)] if recv_body else b''
                body_ok  = (actual == expected)
                body_note = "body OK" if body_ok else "body MISMATCH"
                if not body_ok:
                    body_note += f"\n    sent[0:8]: {expected[:8].hex()}"
                    body_note += f"\n    got [0:8]:  {actual[:8].hex()}"

                src_str = mac_to_str(recv_src) if recv_src else "?"
                dst_str_r = mac_to_str(recv_dst) if recv_dst else "?"

                # Mode-specific validation
                if args.mode == "clean":
                    src_ok = (recv_src == fpga_mac)
                    dst_ok = (recv_dst == pc_mac)
                    frame_ok = (offset == 14) and src_ok and dst_ok and body_ok
                    src_note = "" if src_ok else f"  src WRONG ({src_str})"
                    dst_note = "" if dst_ok else f"  dst WRONG ({dst_str_r})"
                else:
                    # raw: offset 14 or 15 accepted
                    frame_ok = (offset in (14, 15)) and body_ok
                    src_note = f"  src={src_str}"
                    dst_note = ""

                if frame_ok:
                    passed += 1
                    print(f"  PASS  {lbl:<28}  {frame_len}B  [{offset_note}]  {body_note}{src_note}")
                else:
                    status = "FAIL"
                    print(f"  {status}  {lbl:<28}  {frame_len}B  [{offset_note}]  "
                          f"{body_note}{src_note}{dst_note}")
            else:
                print(f"  FAIL  {lbl:<28}  no echo  (timeout {args.timeout:.1f}s)")

            seq += 1
            time.sleep(args.delay)

    sock.close()
    print()
    print(f"Result: {passed}/{total} PASS")
    if offsets:
        for off, cnt in sorted(offsets.items()):
            label_off = {14: "correct", 15: "+1 SFD byte"}.get(off, "unexpected")
            print(f"  offset={off} ({label_off}): {cnt}x")
    return passed == total


def run_sniff(args):
    """Sniff mode: print all raw frames, skip outgoing."""
    try:
        sock = open_sock(args.iface)
    except PermissionError:
        print("[ERR] Needs CAP_NET_RAW -- run with: sudo python3 test_loopback.py --sniff")
        sys.exit(1)

    print(f"Sniffing on {args.iface} (Ctrl-C to stop) ...")
    print()
    PKTTYPE_NAMES = {0: "HOST", 1: "BCAST", 2: "MCAST", 3: "OTHER", 4: "OUTGOING"}
    try:
        while True:
            sock.settimeout(5.0)
            try:
                data, addr = sock.recvfrom(4096)
            except socket.timeout:
                continue
            if len(data) < 14:
                continue
            pkttype = addr[2]
            dst  = mac_to_str(data[0:6])
            src  = mac_to_str(data[6:12])
            etype = struct.unpack('>H', data[12:14])[0]
            body  = data[14:]
            ts    = time.strftime("%H:%M:%S")
            ptype_str = PKTTYPE_NAMES.get(pkttype, str(pkttype))
            print(f"[{ts}] {ptype_str:8s} {src} -> {dst}  "
                  f"EtherType=0x{etype:04X}  {len(data)}B  body[0:8]={body[:8].hex()}")
            idx = data.find(MAGIC)
            if idx >= 0:
                seq = struct.unpack('>H', data[idx+4:idx+6])[0] if idx+6 <= len(data) else -1
                print(f"             MAGIC @ offset={idx}  seq={seq}")
    except KeyboardInterrupt:
        print("\nDone.")
    finally:
        sock.close()


def main():
    p = argparse.ArgumentParser(description="Raw L2 loopback test for eth_test_04")
    p.add_argument("--iface",      default=PC_IFACE,
                   help=f"network interface (default: {PC_IFACE})")
    p.add_argument("--fpga-mac",   default=FPGA_MAC_STR, dest="fpga_mac",
                   help=f"FPGA MAC address (default: {FPGA_MAC_STR})")
    p.add_argument("--mode",       default="clean", choices=["clean", "raw"],
                   help="'clean': strict offset/MAC check; 'raw': legacy SFD-tolerant")
    p.add_argument("--timeout",    type=float, default=TIMEOUT_SEC,
                   help=f"echo timeout per frame in seconds (default: {TIMEOUT_SEC})")
    p.add_argument("--delay",      type=float, default=0.02,
                   help="inter-frame delay in seconds (default: 0.02)")
    p.add_argument("--count",      type=int, default=1,
                   help="repetitions per test case (default: 1)")
    p.add_argument("--broadcast",  action="store_true",
                   help="send to FF:FF:FF:FF:FF:FF (echo returns as broadcast)")
    p.add_argument("--sniff",      action="store_true",
                   help="sniff mode: capture and print all frames")
    args = p.parse_args()

    if args.sniff:
        run_sniff(args)
    else:
        ok = run_tests(args)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
