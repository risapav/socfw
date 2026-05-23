#!/usr/bin/env python3
"""
hw_diag.py — HW diagnosticky skript pre xfcp_test_03.

Posiela READ na kazdy slot (0xFF000000-0xFF060000) a vypisuje:
  - raw TX/RX bajty pre kazdu transakciu
  - kategorizaciu chyby (0B / partial / bad SOP / OK)
  - UART STATUS register po teste (overrun / frame / parity)
  - DIAG countery z axil_diag_ctrl (slot 6 @ 0xFF060000)

Podporuje --baud pre runtime zmenu baud rate bez rebuildovania RTL.
Podporuje --sweep pre automaticky scan 115200/57600/38400/9600.
"""

import argparse
import serial
import struct
import time
import sys

PORT         = '/dev/ttyUSB0'
DEFAULT_BAUD = 115200
CLOCK_HZ     = 50_000_000

SOP_REQ  = 0xFE
SOP_RESP = 0xFD
OP_READ  = 0x10
OP_WRITE = 0x11

_seq_counter = 0


def _next_seq():
    global _seq_counter
    s = _seq_counter & 0xFF
    _seq_counter = (_seq_counter + 1) & 0xFF
    return s


SLOTS = [
    (0, 0xFF000000, "SYSC"),
    (1, 0xFF010000, "UART"),
    (2, 0xFF020000, "LED0"),
    (3, 0xFF030000, "LED1"),
    (4, 0xFF040000, "LED2"),
    (5, 0xFF050000, "SEG7"),
]

EXPECTED_READ  = 26   # SOP(1)+TYPE(1)+SEQ(1)+DEV_TYPE(2)+DEV_STR(16)+DATA(4)+TERM(1)
EXPECTED_WRITE = 22   # SOP(1)+TYPE(1)+SEQ(1)+DEV_TYPE(2)+DEV_STR(16)+TERM(1)

UART_BASE        = 0xFF010000
UART_BAUD_DIV    = UART_BASE + 0x04   # BAUD_PENDING
UART_ERR_CLR     = UART_BASE + 0x0C
UART_STATUS      = UART_BASE + 0x10
UART_BAUD_COMMIT = UART_BASE + 0x1C   # triggers delayed baud switch
UART_BAUD_ACTIVE = UART_BASE + 0x20   # RO readback of active prescaler

DIAG_BASE        = 0xFF060000
DIAG_COMP_ID     = DIAG_BASE + 0x00
DIAG_RX_SEEN     = DIAG_BASE + 0x04
DIAG_RX_ACCEPT   = DIAG_BASE + 0x08
DIAG_RX_LOST     = DIAG_BASE + 0x0C
DIAG_RX_FRAME    = DIAG_BASE + 0x10
DIAG_RX_OVERRUN  = DIAG_BASE + 0x14
DIAG_RX_SOP      = DIAG_BASE + 0x18
DIAG_RX_HDR      = DIAG_BASE + 0x1C
DIAG_RX_BAD_HDR  = DIAG_BASE + 0x20
DIAG_RX_RECOVERY = DIAG_BASE + 0x24
DIAG_RX_DROP     = DIAG_BASE + 0x28
DIAG_FAB_REQ     = DIAG_BASE + 0x2C
DIAG_FAB_RESP    = DIAG_BASE + 0x30
DIAG_TX_BYTES    = DIAG_BASE + 0x34
DIAG_TX_PKT      = DIAG_BASE + 0x38
DIAG_RESET       = DIAG_BASE + 0x3C
DIAG_SNAPSHOT    = DIAG_BASE + 0x40

# Timeouty pre jednotlive baud raty (sekundy)
BAUD_TIMEOUTS = {
    115200: 2.0,
    57600:  2.0,
    38400:  2.5,
    19200:  3.0,
    9600:   5.0,
}

SWEEP_BAUDS = [115200, 57600, 38400, 9600]


def baud_to_div(baud):
    return round(CLOCK_HZ / baud)


def make_read_pkt(addr):
    return bytes([SOP_REQ, OP_READ, _next_seq(), 0x00, 0x04]) + struct.pack(">I", addr)


def make_write_pkt(addr, val):
    return bytes([SOP_REQ, OP_WRITE, _next_seq(), 0x00, 0x04]) + struct.pack(">I", addr) + struct.pack(">I", val)


def classify_rx(raw, expected_len):
    n = len(raw)
    if n == 0:
        return "0B — FPGA neodpovedal (request strateny alebo TX stuck)"
    if n == expected_len:
        if raw[0] != SOP_RESP:
            return f"OK bytes ale zly SOP=0x{raw[0]:02X} (ocakavany 0x{SOP_RESP:02X})"
        return "OK"
    if raw[0] == SOP_RESP:
        return f"Partial {n}/{expected_len}B — spravny SOP_RESP, paket nedokonci"
    return f"Partial {n}/{expected_len}B — prvy bajt=0x{raw[0]:02X} (ocakavany 0x{SOP_RESP:02X})"


def decode_data(raw):
    if len(raw) != EXPECTED_READ:
        return None
    data = struct.unpack(">I", raw[21:25])[0]
    dev_str = raw[5:21]
    try:
        s = dev_str.decode('ascii').rstrip('\x00')
    except Exception:
        s = dev_str.hex()
    return data, s


def recv_with_sop_resync(ser, expected_len, deadline):
    """Scan for SOP_RESP (0xFD) then read remainder. Returns bytes or b'' on timeout."""
    while time.time() < deadline:
        b = ser.read(1)
        if not b:
            continue
        if b[0] != SOP_RESP:
            continue
        buf = bytearray(b)
        remaining = expected_len - 1
        while remaining > 0 and time.time() < deadline:
            chunk = ser.read(remaining)
            if not chunk:
                continue
            buf.extend(chunk)
            remaining -= len(chunk)
        return bytes(buf)
    return b""


def transact(ser, pkt, expected_len, pre_delay=0.2, timeout=2.0):
    """Send pkt, read response with SOP resync, print raw TX/RX and diagnosis."""
    if pre_delay > 0:
        time.sleep(pre_delay)
    ser.reset_input_buffer()
    t0 = time.time()
    ser.write(pkt)
    raw = recv_with_sop_resync(ser, expected_len, t0 + timeout)
    elapsed = (time.time() - t0) * 1000

    status = classify_rx(raw, expected_len)

    print(f"  TX ({len(pkt)}B): {pkt.hex(' ')}")
    if len(raw) > 0:
        print(f"  RX ({len(raw)}B): {raw.hex(' ')}")
    else:
        print(f"  RX: <prazdne>")
    print(f"  {elapsed:.1f} ms  |  {status}")

    if status == "OK":
        result = decode_data(raw)
        if result:
            data, dev_str = result
            print(f"  DATA=0x{data:08X}  DEV_STR='{dev_str}'")

    return raw


def set_baud(ser, new_baud):
    """
    Switch both FPGA and PC UART to new_baud using safe pending/commit protocol.

    BAUD_PENDING is retried up to 5 times. BAUD_COMMIT timeout does not abort --
    commit may have happened even if ACK was lost. Both new and old baud are
    verified after the switch window.
    Returns True on success, False if FPGA is confirmed on old baud, raises on unknown state.
    """
    div = baud_to_div(new_baud)
    old_baud = ser.baudrate

    # 1. Write BAUD_PENDING with retries (coupling may drop some WRITEs)
    pending_ok = False
    for attempt in range(5):
        pkt = make_write_pkt(UART_BAUD_DIV, div)
        ser.reset_input_buffer()
        ser.write(pkt)
        raw = recv_with_sop_resync(ser, EXPECTED_WRITE, time.time() + 2.0)
        if len(raw) == EXPECTED_WRITE:
            pending_ok = True
            break
        time.sleep(0.05)

    if not pending_ok:
        return False

    # 2. Write BAUD_COMMIT. ACK is useful but commit may have happened even on timeout.
    pkt_commit = make_write_pkt(UART_BAUD_COMMIT, 1)
    ser.reset_input_buffer()
    ser.write(pkt_commit)
    recv_with_sop_resync(ser, EXPECTED_WRITE, time.time() + 2.0)
    # Intentionally ignore result -- FPGA may have committed even without ACK

    # 3. Wait for FPGA countdown to finish
    time.sleep(0.20)

    # 4. Try new baud
    ser.baudrate = new_baud
    time.sleep(0.05)
    ser.reset_input_buffer()
    vfy = make_read_pkt(DIAG_COMP_ID)
    ser.write(vfy)
    raw = recv_with_sop_resync(ser, EXPECTED_READ, time.time() + 3.0)
    if len(raw) == EXPECTED_READ:
        val = struct.unpack(">I", raw[20:24])[0]
        if val == 0x44494147:
            return True

    # 5. Fallback: commit may not have happened
    ser.baudrate = old_baud
    time.sleep(0.05)
    ser.reset_input_buffer()
    vfy = make_read_pkt(DIAG_COMP_ID)
    ser.write(vfy)
    raw = recv_with_sop_resync(ser, EXPECTED_READ, time.time() + 3.0)
    if len(raw) == EXPECTED_READ:
        val = struct.unpack(">I", raw[20:24])[0]
        if val == 0x44494147:
            return False

    # 6. Unknown state
    raise RuntimeError(f"Cannot determine UART baud after switch {old_baud}->{new_baud}")


def uart_clear_errors(ser, timeout=2.0):
    pkt = make_write_pkt(UART_ERR_CLR, 0x00000001)
    ser.reset_input_buffer()
    ser.write(pkt)
    raw = recv_with_sop_resync(ser, EXPECTED_WRITE, time.time() + timeout)
    return len(raw) == EXPECTED_WRITE


def uart_read_status(ser, timeout=2.0):
    pkt = make_read_pkt(UART_STATUS)
    ser.reset_input_buffer()
    ser.write(pkt)
    raw = recv_with_sop_resync(ser, EXPECTED_READ, time.time() + timeout)
    if len(raw) == EXPECTED_READ:
        return struct.unpack(">I", raw[20:24])[0]
    return None


def diag_reset(ser, timeout=2.0):
    pkt = make_write_pkt(DIAG_RESET, 0x00000001)
    ser.reset_input_buffer()
    ser.write(pkt)
    recv_with_sop_resync(ser, EXPECTED_WRITE, time.time() + timeout)


def diag_snapshot(ser, timeout=2.0):
    pkt = make_write_pkt(DIAG_SNAPSHOT, 0x00000001)
    ser.reset_input_buffer()
    ser.write(pkt)
    recv_with_sop_resync(ser, EXPECTED_WRITE, time.time() + timeout)


def diag_read_all(ser, timeout=2.0):
    """Snapshot live counters then read all 14 diagnostic shadow registers.
    Note: DIAG_SNAPSHOT write is itself 1 extra XFCP transaction included in snapshot.
    Returns dict with None per failed read."""
    diag_snapshot(ser, timeout)
    addrs = [
        ("rx_seen",     DIAG_RX_SEEN),
        ("rx_accept",   DIAG_RX_ACCEPT),
        ("rx_lost",     DIAG_RX_LOST),
        ("rx_frame",    DIAG_RX_FRAME),
        ("rx_overrun",  DIAG_RX_OVERRUN),
        ("rx_sop",      DIAG_RX_SOP),
        ("rx_hdr",      DIAG_RX_HDR),
        ("rx_bad_hdr",  DIAG_RX_BAD_HDR),
        ("rx_recovery", DIAG_RX_RECOVERY),
        ("rx_drop",     DIAG_RX_DROP),
        ("fab_req",     DIAG_FAB_REQ),
        ("fab_resp",    DIAG_FAB_RESP),
        ("tx_bytes",    DIAG_TX_BYTES),
        ("tx_pkt",      DIAG_TX_PKT),
    ]
    result = {}
    for name, addr in addrs:
        time.sleep(0.05)
        pkt = make_read_pkt(addr)
        ser.reset_input_buffer()
        ser.write(pkt)
        raw = recv_with_sop_resync(ser, EXPECTED_READ, time.time() + timeout)
        if len(raw) == EXPECTED_READ:
            result[name] = struct.unpack(">I", raw[20:24])[0]
        else:
            result[name] = None
    return result


def print_diag(label, counters, total_tx=None):
    print(f"\n[DIAG] {label}:")
    print(f"  rx_seen={counters.get('rx_seen')}  "
          f"rx_accept={counters.get('rx_accept')}  "
          f"rx_lost={counters.get('rx_lost')}")
    print(f"  rx_frame={counters.get('rx_frame')}  "
          f"rx_overrun={counters.get('rx_overrun')}  "
          f"rx_sop={counters.get('rx_sop')}  "
          f"rx_hdr={counters.get('rx_hdr')}")
    print(f"  rx_bad_hdr={counters.get('rx_bad_hdr')}  "
          f"rx_recovery={counters.get('rx_recovery')}  "
          f"rx_drop={counters.get('rx_drop')}")
    print(f"  fab_req={counters.get('fab_req')}  "
          f"fab_resp={counters.get('fab_resp')}  "
          f"tx_bytes={counters.get('tx_bytes')}  "
          f"tx_pkt={counters.get('tx_pkt')}")
    if total_tx is not None:
        exp_rx_seen = total_tx * 8   # 8B per READ request
        exp_pkt     = total_tx
        exp_tx      = total_tx * 25  # 25B per READ response
        print(f"  Ocakavane (READ): rx_seen~{exp_rx_seen}  "
              f"rx_hdr~{total_tx}  tx_pkt={exp_pkt}  tx_bytes~{exp_tx}")
        print(f"  (Pozn: DIAG_SNAPSHOT pridat 1 extra transakciu do snapshotu)")
        rx_s = counters.get('rx_seen')
        rx_h = counters.get('rx_hdr')
        rx_l = counters.get('rx_lost')
        rx_f = counters.get('rx_frame')
        rx_r = counters.get('rx_recovery')
        rx_b = counters.get('rx_bad_hdr')
        tx_p = counters.get('tx_pkt')
        tx_b = counters.get('tx_bytes')
        if rx_h is not None and rx_h < total_tx:
            pct_lost = 100 * (total_tx - rx_h) // total_tx
            print(f"  *** rx_hdr={rx_h} < {total_tx}: {pct_lost}% requestov stratilo sa!")
        if rx_l and rx_l > 0:
            print(f"  *** rx_lost={rx_l}: bajty zahadzovane na FIFO vstupe (flush aktualny?)")
        if rx_f and rx_f > 0:
            print(f"  *** rx_frame={rx_f}: frame errory -> TX->RX coupling alebo noise!")
        if rx_r and rx_r > 0:
            print(f"  *** rx_recovery={rx_r}: SOP recovery events (resyncs)")
        if rx_b and rx_b > 0:
            print(f"  *** rx_bad_hdr={rx_b}: bad opcode/count v S_DECODE")
        if tx_p is not None and tx_p < exp_pkt:
            print(f"  *** tx_pkt={tx_p} < {exp_pkt}: FPGA neodoslalo vsetky odpovede!")


def run_test(ser, repeat, timeout, pause_ms=0):
    """Run full slot scan, return (pass_count, fail_count, zero_bytes, partial)."""
    pass_count = fail_count = zero_bytes = partial = 0

    for slot, addr, name in SLOTS:
        for i in range(repeat):
            tag = f"Slot {slot} ({name}) @ 0x{addr:08X}  [#{i+1}]"
            print(f"\n{tag}")
            pkt = make_read_pkt(addr)
            if pause_ms > 0:
                time.sleep(pause_ms / 1000)
            raw = transact(ser, pkt, EXPECTED_READ, timeout=timeout)

            n = len(raw)
            if n == EXPECTED_READ and raw[0] == SOP_RESP:
                pass_count += 1
            else:
                fail_count += 1
                if n == 0:
                    zero_bytes += 1
                elif n < EXPECTED_READ:
                    partial += 1

    return pass_count, fail_count, zero_bytes, partial


def print_result(pass_count, fail_count, zero_bytes, partial):
    total = pass_count + fail_count
    print("\n" + "=" * 65)
    print(f"Vysledok: {pass_count}/{total} OK  ({fail_count} failed)")
    if fail_count > 0:
        print(f"  z toho: 0B={zero_bytes}  partial={partial}"
              f"  bad_resp={fail_count - zero_bytes - partial}")
    if fail_count == 0:
        print("KOMPLETNY USPECH")
    elif pass_count == 0:
        print("KOMPLETNY VYPADOK — FPGA neodpoveda")
    else:
        pct = pass_count * 100 // total
        print(f"CIASTOCNY USPECH {pct}%")


def main():
    parser = argparse.ArgumentParser(
        description='XFCP HW diagnosticky skript pre xfcp_test_03',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Priklady:
  hw_diag.py /dev/ttyUSB0 10
  hw_diag.py /dev/ttyUSB0 10 --baud 57600
  hw_diag.py /dev/ttyUSB0 5 --sweep
  hw_diag.py /dev/ttyUSB0 5 --pause 100"""
    )
    parser.add_argument('port',   nargs='?', default=PORT,
                        help='Serial port (default /dev/ttyUSB0)')
    parser.add_argument('repeat', nargs='?', type=int, default=2,
                        help='Pocet opakovani na slot (default 2)')
    parser.add_argument('--baud', type=int, default=DEFAULT_BAUD,
                        choices=sorted(BAUD_TIMEOUTS.keys()),
                        help='UART baud rate (default 115200)')
    parser.add_argument('--sweep', action='store_true',
                        help=f'Sweep baud rates: {SWEEP_BAUDS}')
    parser.add_argument('--pause', type=int, default=0, metavar='MS',
                        help='Pause before each transaction in milliseconds (default 0)')
    args = parser.parse_args()

    target_baud = args.baud
    timeout = BAUD_TIMEOUTS.get(target_baud, 2.0)

    print(f"Port: {args.port} @ {DEFAULT_BAUD} baud (startup)  opakovat={args.repeat}x")
    print("=" * 65)

    try:
        ser = serial.Serial(args.port, DEFAULT_BAUD, timeout=max(timeout, 2.0))
    except Exception as e:
        print(f"CHYBA: {e}")
        sys.exit(1)

    time.sleep(0.3)

    # If sweep mode, test all baud rates; otherwise single baud
    if args.sweep:
        sweep_results = {}

        for baud in SWEEP_BAUDS:
            baud_timeout = BAUD_TIMEOUTS.get(baud, 2.0)

            # Switch to target baud (skip if already at default for first iteration)
            if baud != DEFAULT_BAUD or (baud == DEFAULT_BAUD and baud != ser.baudrate):
                if ser.baudrate != baud:
                    print(f"\n{'='*65}")
                    print(f"Prepínam na {baud} baud...")
                    ok = set_baud(ser, baud)
                    ser.timeout = max(baud_timeout, 2.0)
                    if ok:
                        print(f"  OK — FPGA a PC su na {baud} baud")
                    else:
                        print(f"  VAROVANIE: baud switch na {baud} — overenie zlyhalo, pokracujem")

            print(f"\n{'='*65}")
            print(f"=== BAUD {baud} ===")
            print(f"{'='*65}")

            print("\n[PRE] Cistim UART sticky errors...")
            ok = uart_clear_errors(ser, baud_timeout)
            print(f"  ERR_CLR write: {'OK' if ok else 'TIMEOUT'}")
            print("[PRE] Resetujem DIAG countery...")
            diag_reset(ser, baud_timeout)
            time.sleep(0.1)

            p, f, z, part = run_test(ser, args.repeat, baud_timeout, pause_ms=args.pause)

            print("\n" + "=" * 65)
            status = uart_read_status(ser, baud_timeout)
            if status is None:
                print(f"[POST] UART STATUS: TIMEOUT")
            else:
                frame   = bool(status & 0x08)
                overrun = bool(status & 0x04)
                parity  = bool(status & 0x10)
                print(f"[POST] UART STATUS: overrun={overrun}  frame={frame}  parity={parity}")

            diag = diag_read_all(ser, baud_timeout)
            print_diag(f"Po teste @ {baud}", diag, total_tx=(p + f))

            print_result(p, f, z, part)
            sweep_results[baud] = (p, f)

        # Summary table
        print(f"\n{'='*65}")
        print("SWEEP ZHRNUTIE:")
        print(f"  {'Baud':>8}  {'OK':>5}  {'Total':>5}  {'%':>5}")
        print(f"  {'-'*8}  {'-'*5}  {'-'*5}  {'-'*5}")
        for baud in SWEEP_BAUDS:
            if baud in sweep_results:
                p, f = sweep_results[baud]
                total = p + f
                pct = p * 100 // total if total else 0
                print(f"  {baud:>8}  {p:>5}  {total:>5}  {pct:>4}%")

    else:
        # Single baud mode
        if target_baud != DEFAULT_BAUD:
            print(f"\nPrepínam na {target_baud} baud...")
            ok = set_baud(ser, target_baud)
            ser.timeout = max(timeout, 2.0)
            if ok:
                print(f"  OK — FPGA a PC su na {target_baud} baud")
            else:
                print(f"  VAROVANIE: baud switch — overenie zlyhalo, pokracujem")

        print(f"\nBaud: {target_baud}  timeout={timeout}s  opakovat={args.repeat}x")

        print("\n[PRE] Cistim UART sticky errors...")
        ok = uart_clear_errors(ser, timeout)
        print(f"  ERR_CLR write: {'OK' if ok else 'TIMEOUT'}")

        print("[PRE] Resetujem DIAG countery...")
        diag_reset(ser, timeout)
        time.sleep(0.1)

        pass_count, fail_count, zero_bytes, partial = run_test(ser, args.repeat, timeout,
                                                                pause_ms=args.pause)

        print("\n" + "=" * 65)
        print("[POST] UART STATUS register (0xFF010010):")
        status = uart_read_status(ser, timeout)
        if status is None:
            print("  TIMEOUT — FPGA neodpovedal ani na STATUS read")
        else:
            tx_busy = bool(status & 0x01)
            rx_busy = bool(status & 0x02)
            overrun = bool(status & 0x04)
            frame   = bool(status & 0x08)
            parity  = bool(status & 0x10)
            print(f"  RAW=0x{status:08X}  tx_busy={tx_busy}  rx_busy={rx_busy}")
            print(f"  overrun={overrun}  frame={frame}  parity={parity}")
            if overrun:
                print("  *** OVERRUN: RX prijimal bajty rychlejsie ako parser cital")
            if frame:
                print("  *** FRAME ERROR: nespravny stop bit — TX→RX coupling alebo baud mismatch")
            if not (overrun or frame or parity):
                print("  OK — ziadne chyby")

        print("\n[POST] DIAG counters (slot 6 @ 0xFF060000):")
        diag = diag_read_all(ser, timeout)
        print_diag("Po teste", diag, total_tx=(pass_count + fail_count))

        print_result(pass_count, fail_count, zero_bytes, partial)

    ser.close()


if __name__ == "__main__":
    main()
