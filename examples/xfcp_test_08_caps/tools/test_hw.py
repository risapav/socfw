#!/usr/bin/env python3
"""
test_hw.py — skriptovany HW test pre xfcp_test_08_caps.

Pouzitie:
  python3 test_hw.py --uart /dev/ttyUSB0
  python3 test_hw.py --udp 192.168.0.5:50000
  python3 test_hw.py --uart /dev/ttyUSB0 --caps --rw --stream --diag
  python3 test_hw.py --udp 192.168.0.5:50000 --caps --repeat 5
"""

import argparse
import sys
from colorama import Fore, Style, init

from xfcp.bus import XfcpBus
from xfcp import protocol as proto
from xfcp.errors import XfcpTimeoutError, XfcpProtocolError, XfcpStatusError
from core.scanner import DynamicScanner

init(autoreset=True)

EXPECTED_IDS = {
    0xFF000000: (0x53595343, "SYSC"),
    0xFF010000: (0x55415254, "UART"),
    0xFF020000: (0x4F55545F, "OUT_"),
    0xFF030000: (0x4F55545F, "OUT_"),
    0xFF040000: (0x4F55545F, "OUT_"),
    0xFF050000: (0x53454737, "SEG7"),
    0xFF060000: (0x44494147, "DIAG"),
}

EXPECTED_CAPS = {
    "proto_major":      1,
    "proto_minor":      1,
    "num_axil_slots":   7,
    "num_stream_slots": 1,
    "max_stream_bytes": 256,
    "stream_align":     4,
    "caps_flags":       0x07,
}

CAPS_FLAGS_NAMES = {0: "HAS_AXIL", 1: "HAS_STREAM", 2: "HAS_CAPS"}

PASS = f"{Fore.GREEN}PASS{Style.RESET_ALL}"
FAIL = f"{Fore.RED}FAIL{Style.RESET_ALL}"

STREAM_TEST_VECTORS = [
    ("4B DEADBEEF", bytes([0xDE, 0xAD, 0xBE, 0xEF])),
    ("16B incr",    bytes(range(16))),
    ("64B incr",    bytes(i & 0xFF for i in range(64))),
    ("256B max",    bytes(i & 0xFF for i in range(256))),
]


def check_id(bus, addr, expected_val, name, repeat):
    ok = 0
    for i in range(repeat):
        val = bus.read32(addr)
        if val == expected_val:
            ok += 1
        else:
            got = f"0x{val:08X}" if val is not None else "TIMEOUT"
            print(f"  [{i+1}] @ 0x{addr:08X} {name}: {Fore.RED}got {got}{Style.RESET_ALL}")
    return ok


def run_slot_tests(bus, repeat):
    passed = 0
    failed = 0
    print(f"\n{Fore.CYAN}--- Slot scan ({repeat}x each) ---")
    for addr, (exp_val, name) in sorted(EXPECTED_IDS.items()):
        ok = check_id(bus, addr, exp_val, name, repeat)
        total = repeat
        if ok == total:
            print(f"  Slot @ 0x{addr:08X}  {name}  {PASS}  ({ok}/{total})")
            passed += total
        else:
            print(f"  Slot @ 0x{addr:08X}  {name}  {FAIL}  ({ok}/{total})")
            failed += total - ok
            passed += ok
    return passed, failed


def run_caps_test(bus, repeat):
    print(f"\n{Fore.CYAN}--- GET_CAPS test ({repeat}x) ---")
    passed = 0
    failed = 0
    for i in range(repeat):
        caps = bus.get_caps()
        if caps is None:
            print(f"  [{i+1}] GET_CAPS: {FAIL}  (TIMEOUT / protocol error)")
            failed += 1
            continue
        ok = True
        for field, expected in EXPECTED_CAPS.items():
            got = caps.get(field)
            if got != expected:
                print(f"  [{i+1}] {field}: got {got} != {expected}  {FAIL}")
                ok = False
        if ok:
            passed += 1
        else:
            failed += 1

    flags = None
    caps = bus.get_caps()
    if caps:
        flags = caps["caps_flags"]
        flags_str = " | ".join(
            name for bit, name in CAPS_FLAGS_NAMES.items() if flags & (1 << bit)
        )
        print(f"  caps_flags=0x{flags:02X} ({flags_str})")
        print(f"  proto={caps['proto_major']}.{caps['proto_minor']}  "
              f"axil={caps['num_axil_slots']}  "
              f"stream={caps['num_stream_slots']}  "
              f"max_stream={caps['max_stream_bytes']}B")

    status = PASS if failed == 0 else FAIL
    print(f"  GET_CAPS  {status}  ({passed}/{repeat})")
    return passed, failed


def run_rw_test(bus):
    print(f"\n{Fore.CYAN}--- Read/Write test (LED @ 0xFF020004) ---")
    results = []
    for val in [0x00, 0x15, 0x2A, 0x3F, 0x00]:
        ok = bus.write32(0xFF020004, val)
        rb = bus.read32(0xFF020004)
        match = (rb == val)
        status = PASS if (ok and match) else FAIL
        rb_str = f"0x{rb:02X}" if rb is not None else "TIMEOUT"
        print(f"  write 0x{val:02X} -> readback {rb_str}  {status}")
        results.append(ok and match)
    passed = sum(results)
    failed = len(results) - passed
    return passed, failed


def debug_stream_write(bus, data):
    """Raw stream_write s plnym logom response bajtov — pre diagnozu HW problemov."""
    seq = bus._next_seq()
    pkt = proto.encode_stream_write(data, stream_id=0, seq=seq)
    exp = proto.resp_len_stream_write()
    print(f"  TX ({len(pkt)}B): {pkt.hex()}")
    bus._transport.flush_rx()
    bus._transport.write(pkt)
    raw = bus._transport.read_packet(exp)
    print(f"  RX ({len(raw)}B): {raw.hex() if raw else '(prazdne)'}")
    if len(raw) != exp:
        print(f"  -> XfcpTimeoutError: got {len(raw)}/{exp} bytes")
        return False
    try:
        proto.decode_stream_write_response(raw, expected_seq=seq)
        print(f"  -> OK")
        return True
    except XfcpProtocolError as e:
        print(f"  -> XfcpProtocolError: {e}")
    except XfcpStatusError as e:
        print(f"  -> XfcpStatusError: {e}")
    return False


def run_stream_loopback_test(bus, repeat, debug=False):
    print(f"\n{Fore.CYAN}--- Stream loopback test (sid=0, {repeat}x each) ---")
    passed = 0
    failed = 0
    first_fail_shown = False
    for name, data in STREAM_TEST_VECTORS:
        ok_count = 0
        for i in range(repeat):
            if debug and not first_fail_shown:
                print(f"\n  [DEBUG] {name} [{i+1}] stream_write ({len(data)}B):")
                ok_wr = debug_stream_write(bus, data)
                first_fail_shown = not ok_wr
            else:
                ok_wr = bus.stream_write(data)
            if not ok_wr:
                print(f"  [{name}] [{i+1}] stream_write: {FAIL}")
                failed += 1
                continue
            rx = bus.stream_read(len(data))
            if rx == data:
                ok_count += 1
                passed += 1
            else:
                got = rx.hex()[:32] if rx is not None else "TIMEOUT"
                print(f"  [{name}] [{i+1}] mismatch: got {got}... {FAIL}")
                failed += 1
        status = PASS if ok_count == repeat else FAIL
        print(f"  {name:<18} {status}  ({ok_count}/{repeat})")
    return passed, failed


def dump_diag(bus):
    print(f"\n{Fore.CYAN}--- DIAG counters (snapshot) ---")
    DIAG = 0xFF060000
    bus.write32(DIAG + 0x40, 1)  # snapshot
    names = [
        ("rx_seen",     0x04), ("rx_accept",   0x08), ("rx_lost",     0x0C),
        ("rx_frame",    0x10), ("rx_overrun",  0x14), ("rx_sop",      0x18),
        ("rx_hdr",      0x1C), ("rx_bad_hdr",  0x20), ("rx_recovery", 0x24),
        ("rx_drop",     0x28), ("fab_req",     0x2C), ("fab_resp",    0x30),
        ("tx_byte",     0x34), ("tx_pkt",      0x38),
    ]
    errors = 0
    for name, off in names:
        val = bus.read32(DIAG + off)
        valstr = f"0x{val:08X}" if val is not None else f"{Fore.RED}TIMEOUT{Style.RESET_ALL}"
        if name in ("rx_lost", "rx_frame", "rx_overrun", "rx_bad_hdr", "rx_drop") and val:
            valstr = f"{Fore.YELLOW}{val}{Style.RESET_ALL}"
            errors += 1
        print(f"  {name:<14} {valstr}")
    if errors:
        print(f"\n  {Fore.YELLOW}Upozornenie: {errors} nenulove chybove registre.{Style.RESET_ALL}")
    else:
        print(f"\n  {Fore.GREEN}Bez chyb.{Style.RESET_ALL}")


def main():
    parser = argparse.ArgumentParser(description="xfcp_test_08_caps HW test")
    grp = parser.add_mutually_exclusive_group(required=True)
    grp.add_argument("--uart", metavar="PORT",
                     help="UART transport, napr. /dev/ttyUSB0")
    grp.add_argument("--udp",  metavar="HOST[:PORT]",
                     help="UDP transport, napr. 192.168.0.5:50000")
    parser.add_argument("--baud",   type=int, default=115200)
    parser.add_argument("--repeat", type=int, default=3,
                        help="Pocet opakovani na slot/caps (default 3)")
    parser.add_argument("--caps",   action="store_true",
                        help="Spusti GET_CAPS test (overenie 8B caps payload)")
    parser.add_argument("--rw",     action="store_true",
                        help="Pridaj R/W test na LED register")
    parser.add_argument("--stream", action="store_true",
                        help="Spusti stream loopback test (STREAM_WRITE/READ sid=0)")
    parser.add_argument("--debug-stream", action="store_true",
                        help="Pri prvom STREAM zlyhani vypis surove TX/RX bajty")
    parser.add_argument("--diag",   action="store_true",
                        help="Vypis DIAG countere na konci")
    args = parser.parse_args()

    if args.uart:
        bus = XfcpBus.uart(port=args.uart, baudrate=args.baud)
        label = f"UART {args.uart}@{args.baud}"
    else:
        parts = args.udp.rsplit(":", 1)
        host = parts[0]
        port = int(parts[1]) if len(parts) > 1 else 50000
        bus = XfcpBus.udp(host=host, port=port)
        label = f"UDP {host}:{port}"

    print(f"\n{Fore.LIGHTWHITE_EX}=== xfcp_test_08_caps HW test  [{label}] ===")

    total_pass = 0
    total_fail = 0

    try:
        with bus:
            print(f"\n{Fore.CYAN}--- Ping ---")
            if not bus.ping():
                print(f"  {FAIL}  SoC neodpoveda")
                sys.exit(1)
            print(f"  {PASS}  SoC odpoveda")

            p, f = run_slot_tests(bus, args.repeat)
            total_pass += p
            total_fail += f

            if args.caps:
                p, f = run_caps_test(bus, args.repeat)
                total_pass += p
                total_fail += f

            if args.rw:
                p, f = run_rw_test(bus)
                total_pass += p
                total_fail += f

            if args.stream:
                p, f = run_stream_loopback_test(bus, args.repeat,
                                                debug=getattr(args, 'debug_stream', False))
                total_pass += p
                total_fail += f

            if args.diag:
                dump_diag(bus)

    except Exception as e:
        print(f"\n{Fore.RED}[FATAL] {type(e).__name__}: {e}")
        sys.exit(2)

    total = total_pass + total_fail
    print(f"\n{'='*50}")
    if total_fail == 0:
        print(f"  {PASS}  {total_pass}/{total} — KOMPLETNY USPECH")
    elif total_pass == 0:
        print(f"  {FAIL}  0/{total} — KOMPLETNY VYPADOK")
    else:
        pct = total_pass * 100 // total
        print(f"  {FAIL}  {total_pass}/{total} ({pct}%) — CIASTOCNY USPECH")
    print(f"{'='*50}")

    sys.exit(0 if total_fail == 0 else 1)


if __name__ == "__main__":
    main()
