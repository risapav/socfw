#!/usr/bin/env python3
"""
test_hw.py -- skriptovany HW test pre xfcp_test_11_cpu_mailbox.

Pouzitie:
  python3 test_hw.py --uart /dev/ttyUSB0
  python3 test_hw.py --udp 192.168.0.5:50000
  python3 test_hw.py --uart /dev/ttyUSB0 --caps --rw --stream --cpu0 --targets --mem --diag
  python3 test_hw.py --udp 192.168.0.5:50000 --stream --cpu0 --repeat 3
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
    "proto_minor":      3,
    "num_axil_slots":   7,
    "num_stream_slots": 2,
    "max_stream_bytes": 256,
    "stream_align":     4,
    "caps_flags":       0x1F,
}

CAPS_FLAGS_NAMES = {
    0: "HAS_AXIL", 1: "HAS_STREAM", 2: "HAS_CAPS", 3: "HAS_TARGETS", 4: "HAS_MEM"
}

TARGET_TYPES = {0x01: "AXIL", 0x02: "STREAM", 0x03: "MEM"}

EXPECTED_TARGET_TABLE = [
    {"target_type": 0x01, "target_id": 0, "base_addr": 0xFF000000,
     "max_transfer": 128, "align": 4, "name": "SYSC"},
    {"target_type": 0x01, "target_id": 1, "base_addr": 0xFF010000,
     "max_transfer": 128, "align": 4, "name": "UART"},
    {"target_type": 0x01, "target_id": 2, "base_addr": 0xFF020000,
     "max_transfer": 128, "align": 4, "name": "OUT_"},
    {"target_type": 0x01, "target_id": 3, "base_addr": 0xFF030000,
     "max_transfer": 128, "align": 4, "name": "OUT_"},
    {"target_type": 0x01, "target_id": 4, "base_addr": 0xFF040000,
     "max_transfer": 128, "align": 4, "name": "OUT_"},
    {"target_type": 0x01, "target_id": 5, "base_addr": 0xFF050000,
     "max_transfer": 128, "align": 4, "name": "SEG7"},
    {"target_type": 0x01, "target_id": 6, "base_addr": 0xFF060000,
     "max_transfer": 128, "align": 4, "name": "DIAG"},
    {"target_type": 0x02, "target_id": 7, "base_addr": 0x00000000,
     "max_transfer": 256, "align": 4, "name": "STR0"},
    {"target_type": 0x03, "target_id": 8, "base_addr": 0x00000000,
     "max_transfer": 256, "align": 4, "name": "MEM0"},
    {"target_type": 0x02, "target_id": 9, "base_addr": 0x00000001,
     "max_transfer": 256, "align": 4, "name": "CPU0"},
]

PASS = f"{Fore.GREEN}PASS{Style.RESET_ALL}"
FAIL = f"{Fore.RED}FAIL{Style.RESET_ALL}"

MEM_BASE_ADDR = 0x00000000

MEM_TEST_VECTORS = [
    ("4B",   bytes([0xDE, 0xAD, 0xBE, 0xEF])),
    ("16B",  bytes(range(16))),
    ("64B",  bytes(i & 0xFF for i in range(64))),
    ("256B", bytes(i & 0xFF for i in range(256))),
]

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


def run_target_info_test(bus, repeat):
    print(f"\n{Fore.CYAN}--- GET_TARGET_INFO test ({repeat}x each, {len(EXPECTED_TARGET_TABLE)} targets) ---")
    passed = 0
    failed = 0
    check_fields = ["target_type", "target_id", "base_addr", "max_transfer", "align", "name"]
    for i, exp in enumerate(EXPECTED_TARGET_TABLE):
        ok_count = 0
        for _ in range(repeat):
            ti = bus.get_target_info(i)
            if ti is None:
                failed += 1
                continue
            ok = all(ti.get(f) == exp[f] for f in check_fields)
            if ok:
                ok_count += 1
                passed += 1
            else:
                for f in check_fields:
                    if ti.get(f) != exp[f]:
                        print(f"  [idx={i}] {f}: got {ti.get(f)!r} != {exp[f]!r}  {FAIL}")
                failed += 1
        type_str = TARGET_TYPES.get(exp["target_type"], "?")
        status = PASS if ok_count == repeat else FAIL
        print(f"  [{i}] {exp['name']:<6} {type_str:<8} base=0x{exp['base_addr']:08X}"
              f"  {status}  ({ok_count}/{repeat})")
    bad_ti = bus.get_target_info(len(EXPECTED_TARGET_TABLE))
    if bad_ti is None:
        print(f"  [idx={len(EXPECTED_TARGET_TABLE)}] BAD_ADDRESS  {PASS}")
        passed += 1
    else:
        print(f"  [idx={len(EXPECTED_TARGET_TABLE)}] BAD_ADDRESS expected, got {bad_ti}  {FAIL}")
        failed += 1
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


def run_stream_loopback_test(bus, repeat, stream_id=0, label="STR0"):
    print(f"\n{Fore.CYAN}--- Stream loopback test (sid={stream_id} {label}, {repeat}x each) ---")
    passed = 0
    failed = 0
    for name, data in STREAM_TEST_VECTORS:
        ok_count = 0
        for i in range(repeat):
            ok_wr = bus.stream_write(data, stream_id=stream_id)
            if not ok_wr:
                print(f"  [{name}] [{i+1}] stream_write: {FAIL}")
                failed += 1
                continue
            rx = bus.stream_read(len(data), stream_id=stream_id)
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


def run_mem_test(bus, repeat):
    print(f"\n{Fore.CYAN}--- MEM loopback test (addr=0x{MEM_BASE_ADDR:08X}, {repeat}x each) ---")
    passed = 0
    failed = 0
    for name, data in MEM_TEST_VECTORS:
        ok_count = 0
        for _ in range(repeat):
            ok_wr = bus.mem_write(MEM_BASE_ADDR, data)
            if not ok_wr:
                print(f"  [{name}] mem_write: {FAIL}")
                failed += 1
                continue
            rx = bus.mem_read(MEM_BASE_ADDR, len(data))
            if rx == data:
                ok_count += 1
                passed += 1
            else:
                got = rx.hex()[:32] if rx is not None else "TIMEOUT"
                print(f"  [{name}] mismatch: got {got}...  {FAIL}")
                failed += 1
        status = PASS if ok_count == repeat else FAIL
        print(f"  {name:<6}  {status}  ({ok_count}/{repeat})")
    return passed, failed


def dump_diag(bus):
    print(f"\n{Fore.CYAN}--- DIAG counters (snapshot) ---")
    DIAG = 0xFF060000
    bus.write32(DIAG + 0x40, 1)
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
    parser = argparse.ArgumentParser(description="xfcp_test_11_cpu_mailbox HW test")
    grp = parser.add_mutually_exclusive_group(required=True)
    grp.add_argument("--uart", metavar="PORT",
                     help="UART transport, napr. /dev/ttyUSB0")
    grp.add_argument("--udp",  metavar="HOST[:PORT]",
                     help="UDP transport, napr. 192.168.0.5:50000")
    parser.add_argument("--baud",    type=int, default=115200)
    parser.add_argument("--repeat",  type=int, default=3,
                        help="Pocet opakovani na slot/caps (default 3)")
    parser.add_argument("--caps",    action="store_true",
                        help="Spusti GET_CAPS test (overenie 8B caps payload)")
    parser.add_argument("--targets", action="store_true",
                        help="Spusti GET_TARGET_INFO test (10 targets + BAD_ADDRESS)")
    parser.add_argument("--rw",      action="store_true",
                        help="Pridaj R/W test na LED register")
    parser.add_argument("--stream",  action="store_true",
                        help="Spusti STR0 loopback test (STREAM_WRITE/READ sid=0)")
    parser.add_argument("--cpu0",    action="store_true",
                        help="Spusti CPU0 loopback test (STREAM_WRITE/READ sid=1)")
    parser.add_argument("--mem",     action="store_true",
                        help="Spusti MEM loopback test (MEM_WRITE/READ, 4-256B)")
    parser.add_argument("--diag",    action="store_true",
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

    print(f"\n{Fore.LIGHTWHITE_EX}=== xfcp_test_11_cpu_mailbox HW test  [{label}] ===")

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

            if args.targets:
                p, f = run_target_info_test(bus, args.repeat)
                total_pass += p
                total_fail += f

            if args.rw:
                p, f = run_rw_test(bus)
                total_pass += p
                total_fail += f

            if args.stream:
                p, f = run_stream_loopback_test(bus, args.repeat, stream_id=0, label="STR0")
                total_pass += p
                total_fail += f

            if args.cpu0:
                p, f = run_stream_loopback_test(bus, args.repeat, stream_id=1, label="CPU0")
                total_pass += p
                total_fail += f

            if args.mem:
                p, f = run_mem_test(bus, args.repeat)
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
        print(f"  {PASS}  {total_pass}/{total} -- KOMPLETNY USPECH")
    elif total_pass == 0:
        print(f"  {FAIL}  0/{total} -- KOMPLETNY VYPADOK")
    else:
        pct = total_pass * 100 // total
        print(f"  {FAIL}  {total_pass}/{total} ({pct}%) -- CIASTOCNY USPECH")
    print(f"{'='*50}")

    sys.exit(0 if total_fail == 0 else 1)


if __name__ == "__main__":
    main()
