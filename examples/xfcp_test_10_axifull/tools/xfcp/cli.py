"""
XFCP command-line client.

Usage (from tools/ directory):
  python3 xfcp_cli.py --uart /dev/ttyUSB0 ping
  python3 xfcp_cli.py --udp  192.168.0.5:50000 caps
  python3 xfcp_cli.py --uart /dev/ttyUSB0 targets
  python3 xfcp_cli.py --udp  192.168.0.5:50000 read32  0xFF020004
  python3 xfcp_cli.py --uart /dev/ttyUSB0 write32 0xFF020004 0x3F
  python3 xfcp_cli.py --udp  192.168.0.5:50000 read    0xFF000000 4
  python3 xfcp_cli.py --uart /dev/ttyUSB0 write   0xFF020004 0x01 0x02
  python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-read  0x00000000 64
  python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-read  0x00000000 64 dump.bin
  python3 xfcp_cli.py --uart /dev/ttyUSB0 mem-write 0x00000000 data.bin
  python3 xfcp_cli.py --uart /dev/ttyUSB0 stream-read  0 16
  python3 xfcp_cli.py --uart /dev/ttyUSB0 stream-write 0 data.bin
"""

import argparse
import sys
import time

from .bus import XfcpBus
from .errors import XfcpError, XfcpStatusError

try:
    from colorama import Fore, Style, init as _cinit
    _cinit(autoreset=True)
    _GREEN  = Fore.GREEN
    _RED    = Fore.RED
    _CYAN   = Fore.CYAN
    _YELLOW = Fore.YELLOW
    _RESET  = Style.RESET_ALL
except ImportError:
    _GREEN = _RED = _CYAN = _YELLOW = _RESET = ""

_STATUS_NAMES = {
    0x00: "OK",          0x01: "BAD_OPCODE",  0x02: "BAD_LENGTH",
    0x03: "BAD_ADDRESS", 0x04: "AXI_SLVERR",  0x05: "AXI_DECERR",
    0x06: "TIMEOUT",     0x07: "BUSY",         0x08: "OVERFLOW",
    0x09: "UNSUPPORTED", 0x7F: "INTERNAL_ERROR",
}

_TARGET_TYPES = {0x01: "AXIL", 0x02: "STREAM", 0x03: "MEM"}

_CAPS_FLAGS = {0: "HAS_AXIL", 1: "HAS_STREAM", 2: "HAS_CAPS",
               3: "HAS_TARGETS", 4: "HAS_MEM"}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _ok(msg="OK"):
    print(f"{_GREEN}OK{_RESET}  {msg}")


def _fail(msg):
    print(f"{_RED}FAIL{_RESET}  {msg}", file=sys.stderr)


def _parse_int(s: str) -> int:
    return int(s, 0)


def _hexdump(data: bytes, base_addr: int = 0) -> None:
    for off in range(0, len(data), 16):
        chunk = data[off:off + 16]
        hex_part = " ".join(f"{b:02X}" for b in chunk)
        asc_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"  {base_addr + off:08X}  {hex_part:<47}  {asc_part}")


def _open_input(path: str) -> bytes:
    if path == "-":
        return sys.stdin.buffer.read()
    with open(path, "rb") as f:
        return f.read()


def _write_output(data: bytes, path: str | None) -> None:
    if path and path != "-":
        with open(path, "wb") as f:
            f.write(data)
        print(f"  zapísané {len(data)} bajtov -> {path}")
    else:
        sys.stdout.buffer.write(data)


def _make_bus(args) -> XfcpBus:
    if args.uart:
        parts = args.uart.split(":")
        port = parts[0]
        baud = int(parts[1]) if len(parts) > 1 else args.baud
        return XfcpBus.uart(port, baud)
    if args.udp:
        host, _, portstr = args.udp.rpartition(":")
        port = int(portstr) if portstr else 50000
        return XfcpBus.udp(host, port)
    raise SystemExit("Chyba: musíš zadať --uart PORT alebo --udp HOST:PORT")


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_ping(bus: XfcpBus, _args) -> int:
    t0 = time.monotonic()
    ok = bus.ping()
    ms = (time.monotonic() - t0) * 1000
    if ok:
        _ok(f"SoC odpovedá  ({ms:.1f} ms)")
        return 0
    _fail("SoC neodpovedá")
    return 1


def cmd_caps(bus: XfcpBus, _args) -> int:
    caps = bus.get_caps()
    if caps is None:
        _fail("GET_CAPS zlyhalo")
        return 1
    flags = caps["caps_flags"]
    flag_str = " | ".join(n for i, n in _CAPS_FLAGS.items() if flags & (1 << i))
    print(f"  proto          {caps['proto_major']}.{caps['proto_minor']}")
    print(f"  axil_slots     {caps['num_axil_slots']}")
    print(f"  stream_slots   {caps['num_stream_slots']}")
    print(f"  max_stream     {caps['max_stream_bytes']} B")
    print(f"  stream_align   {caps['stream_align']}")
    print(f"  caps_flags     0x{flags:02X}  ({flag_str})")
    return 0


def cmd_targets(bus: XfcpBus, _args) -> int:
    targets = bus.list_targets()
    if not targets:
        _fail("Žiadne targety (alebo GET_TARGET_INFO zlyhalo)")
        return 1
    print(f"  {'Idx':<4} {'Názov':<6} {'Typ':<8} {'Base addr':>12}  "
          f"{'max_xfer':>8}  {'align':>5}")
    print("  " + "-" * 56)
    for t in targets:
        ttype = _TARGET_TYPES.get(t["target_type"], f"0x{t['target_type']:02X}")
        print(f"  {t['target_id']:<4} {t['name']:<6} {ttype:<8} "
              f"0x{t['base_addr']:08X}  {t['max_transfer']:>6} B  {t['align']:>5}")
    return 0


def cmd_read32(bus: XfcpBus, args) -> int:
    addr = _parse_int(args.addr)
    val = bus.read32(addr)
    if val is None:
        _fail(f"read32 0x{addr:08X} zlyhalo")
        return 1
    print(f"  0x{addr:08X} = 0x{val:08X}  ({val})")
    return 0


def cmd_write32(bus: XfcpBus, args) -> int:
    addr = _parse_int(args.addr)
    val  = _parse_int(args.value)
    ok = bus.write32(addr, val)
    if not ok:
        _fail(f"write32 0x{addr:08X} <- 0x{val:08X} zlyhalo")
        return 1
    _ok(f"0x{addr:08X} <- 0x{val:08X}")
    return 0


def cmd_read(bus: XfcpBus, args) -> int:
    addr  = _parse_int(args.addr)
    count = int(args.count)
    words = bus.read_block(addr, count)
    if words is None:
        _fail(f"read 0x{addr:08X} {count}w zlyhalo")
        return 1
    data = b"".join(w.to_bytes(4, "big") for w in words)
    _hexdump(data, addr)
    return 0


def cmd_write(bus: XfcpBus, args) -> int:
    addr   = _parse_int(args.addr)
    values = [_parse_int(v) for v in args.values]
    ok = bus.write_block(addr, values)
    if not ok:
        _fail(f"write 0x{addr:08X} {len(values)}w zlyhalo")
        return 1
    _ok(f"0x{addr:08X} <- {len(values)} slov")
    return 0


def cmd_mem_read(bus: XfcpBus, args) -> int:
    addr  = _parse_int(args.addr)
    count = int(args.count)
    if count <= 0 or count % 4 != 0:
        _fail(f"count musí byť kladný násobok 4, dostalo: {count}")
        return 1
    data = bus.mem_read(addr, count)
    if data is None:
        _fail(f"mem-read 0x{addr:08X} {count}B zlyhalo")
        return 1
    outfile = getattr(args, "file", None)
    if outfile:
        _write_output(data, outfile)
    else:
        _hexdump(data, addr)
    return 0


def cmd_mem_write(bus: XfcpBus, args) -> int:
    addr = _parse_int(args.addr)
    data = _open_input(args.file)
    if len(data) == 0 or len(data) % 4 != 0:
        _fail(f"dáta musia byť neprázdny násobok 4 bajtov, dostalo: {len(data)}B")
        return 1
    ok = bus.mem_write(addr, data)
    if not ok:
        _fail(f"mem-write 0x{addr:08X} {len(data)}B zlyhalo")
        return 1
    _ok(f"0x{addr:08X} <- {len(data)} B z {args.file}")
    return 0


def cmd_stream_read(bus: XfcpBus, args) -> int:
    sid   = int(args.sid)
    count = int(args.count)
    if count <= 0 or count % 4 != 0:
        _fail(f"count musí byť kladný násobok 4, dostalo: {count}")
        return 1
    data = bus.stream_read(count, stream_id=sid)
    if data is None:
        _fail(f"stream-read sid={sid} {count}B zlyhalo")
        return 1
    outfile = getattr(args, "file", None)
    if outfile:
        _write_output(data, outfile)
    else:
        _hexdump(data)
    return 0


def cmd_stream_write(bus: XfcpBus, args) -> int:
    sid  = int(args.sid)
    data = _open_input(args.file)
    if len(data) == 0 or len(data) % 4 != 0:
        _fail(f"dáta musia byť neprázdny násobok 4 bajtov, dostalo: {len(data)}B")
        return 1
    ok = bus.stream_write(data, stream_id=sid)
    if not ok:
        _fail(f"stream-write sid={sid} {len(data)}B zlyhalo")
        return 1
    _ok(f"stream sid={sid} <- {len(data)} B z {args.file}")
    return 0


# ---------------------------------------------------------------------------
# argument parser
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="xfcp_cli",
        description="XFCP command-line client",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # transport
    tg = p.add_mutually_exclusive_group(required=True)
    tg.add_argument("--uart", metavar="PORT[:BAUD]",
                    help="UART transport, napr. /dev/ttyUSB0 alebo /dev/ttyUSB0:115200")
    tg.add_argument("--udp",  metavar="HOST:PORT",
                    help="UDP transport, napr. 192.168.0.5:50000")
    p.add_argument("--baud", type=int, default=115200,
                   help="UART baud rate (default 115200, ignoruje sa ak je v --uart)")
    p.add_argument("--retries", type=int, default=1, metavar="N",
                   help="Počet retries pri timeoutu (default 1)")

    sub = p.add_subparsers(dest="command", metavar="COMMAND")
    sub.required = True

    # ping
    sub.add_parser("ping", help="Otestuj spojenie (ping SYSC register)")

    # caps
    sub.add_parser("caps", help="Zobraz GET_CAPS (verzia protokolu, flagy)")

    # targets
    sub.add_parser("targets", help="Vypíš všetky GET_TARGET_INFO záznamy")

    # read32
    s = sub.add_parser("read32", help="Prečítaj 1 register (32b)")
    s.add_argument("addr", help="Adresa (hex alebo dec), napr. 0xFF020004")

    # write32
    s = sub.add_parser("write32", help="Zapíš 1 register (32b)")
    s.add_argument("addr",  help="Adresa")
    s.add_argument("value", help="Hodnota (hex alebo dec)")

    # read (burst)
    s = sub.add_parser("read", help="Burst read N slov (hex dump)")
    s.add_argument("addr",  help="Bazová adresa")
    s.add_argument("count", help="Počet 32-bit slov")

    # write (burst)
    s = sub.add_parser("write", help="Burst write N slov")
    s.add_argument("addr",   help="Bazová adresa")
    s.add_argument("values", nargs="+", help="Hodnoty (hex alebo dec)")

    # mem-read
    s = sub.add_parser("mem-read", help="MEM_READ N bajtov z adresy (hex dump alebo súbor)")
    s.add_argument("addr",  help="Adresa v pamäti")
    s.add_argument("count", help="Počet bajtov (násobok 4, max 256)")
    s.add_argument("file",  nargs="?", default=None,
                   help="Výstupný súbor (vynechaj = hex dump na stdout)")

    # mem-write
    s = sub.add_parser("mem-write", help="MEM_WRITE bajty z súboru na adresu")
    s.add_argument("addr", help="Adresa v pamäti")
    s.add_argument("file", help="Vstupný súbor (- = stdin)")

    # stream-read
    s = sub.add_parser("stream-read", help="STREAM_READ N bajtov (hex dump alebo súbor)")
    s.add_argument("sid",   help="Stream ID (zvyčajne 0)")
    s.add_argument("count", help="Počet bajtov (násobok 4, max 256)")
    s.add_argument("file",  nargs="?", default=None,
                   help="Výstupný súbor (vynechaj = hex dump na stdout)")

    # stream-write
    s = sub.add_parser("stream-write", help="STREAM_WRITE bajty z súboru na stream")
    s.add_argument("sid",  help="Stream ID (zvyčajne 0)")
    s.add_argument("file", help="Vstupný súbor (- = stdin)")

    return p


_COMMANDS = {
    "ping":         cmd_ping,
    "caps":         cmd_caps,
    "targets":      cmd_targets,
    "read32":       cmd_read32,
    "write32":      cmd_write32,
    "read":         cmd_read,
    "write":        cmd_write,
    "mem-read":     cmd_mem_read,
    "mem-write":    cmd_mem_write,
    "stream-read":  cmd_stream_read,
    "stream-write": cmd_stream_write,
}


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    fn = _COMMANDS.get(args.command)
    if fn is None:
        parser.print_help()
        return 1

    try:
        with _make_bus(args) as bus:
            bus._retries = args.retries
            return fn(bus, args)
    except XfcpStatusError as e:
        name = _STATUS_NAMES.get(e.status, f"0x{e.status:02X}")
        _fail(f"FPGA status: {name}")
        return 1
    except XfcpError as e:
        _fail(str(e))
        return 1
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
