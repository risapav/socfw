#!/usr/bin/env python3
"""
hw_diag.py — HW diagnosticky skript pre xfcp_test_03.

Posiela READ na kazdy slot (0xFF000000-0xFF050000) a vypisuje:
  - raw TX/RX bajty pre kazdu transakciu
  - kategorizaciu chyby (0B / partial / bad SOP / OK)
  - UART STATUS register po teste (overrun / frame / parity)

Navrhy_08 krok 3: raw TX/RX log pre diagnostiku 0B timeout.
"""

import serial
import struct
import time
import sys

PORT    = '/dev/ttyUSB0'
BAUD    = 115200
TIMEOUT = 2.0

SOP_REQ  = 0xFE
SOP_RESP = 0xFD
OP_READ  = 0x10
OP_WRITE = 0x11

SLOTS = [
    (0, 0xFF000000, "SYSC"),
    (1, 0xFF010000, "UART"),
    (2, 0xFF020000, "LED0"),
    (3, 0xFF030000, "LED1"),
    (4, 0xFF040000, "LED2"),
    (5, 0xFF050000, "SEG7"),
]

EXPECTED_READ  = 25   # SOP(1)+TYPE(1)+DEV_TYPE(2)+DEV_STR(16)+DATA(4)+TERM(1)
EXPECTED_WRITE = 21   # SOP(1)+TYPE(1)+DEV_TYPE(2)+DEV_STR(16)+TERM(1)

UART_BASE    = 0xFF010000
UART_ERR_CLR = UART_BASE + 0x0C
UART_STATUS  = UART_BASE + 0x10


def make_read_pkt(addr):
    return bytes([SOP_REQ, OP_READ, 0x00, 0x04]) + struct.pack(">I", addr)


def make_write_pkt(addr, val):
    return bytes([SOP_REQ, OP_WRITE, 0x00, 0x04]) + struct.pack(">I", addr) + struct.pack(">I", val)


def classify_rx(raw, expected_len):
    """Return short diagnostic string describing what came back."""
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
    """Extract and format register data from a full READ response."""
    if len(raw) != EXPECTED_READ:
        return None
    data = struct.unpack(">I", raw[20:24])[0]
    dev_str = raw[4:20]
    try:
        s = dev_str.decode('ascii').rstrip('\x00')
    except Exception:
        s = dev_str.hex()
    return data, s


def transact(ser, pkt, expected_len, pre_delay=0.2):
    """Send pkt, read response, print raw TX/RX and diagnosis."""
    if pre_delay > 0:
        time.sleep(pre_delay)
    ser.reset_input_buffer()
    t0 = time.time()
    ser.write(pkt)
    raw = ser.read(expected_len)
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


def uart_clear_errors(ser):
    pkt = make_write_pkt(UART_ERR_CLR, 0x00000001)
    ser.reset_input_buffer()
    ser.write(pkt)
    raw = ser.read(EXPECTED_WRITE)
    return len(raw) == EXPECTED_WRITE


def uart_read_status(ser):
    pkt = make_read_pkt(UART_STATUS)
    ser.reset_input_buffer()
    ser.write(pkt)
    raw = ser.read(EXPECTED_READ)
    if len(raw) == EXPECTED_READ:
        return struct.unpack(">I", raw[20:24])[0]
    return None


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else PORT
    repeat = int(sys.argv[2]) if len(sys.argv) > 2 else 2

    print(f"Port: {port} @ {BAUD} baud  timeout={TIMEOUT}s  opakovat={repeat}x")
    print("=" * 65)

    try:
        ser = serial.Serial(port, BAUD, timeout=TIMEOUT)
    except Exception as e:
        print(f"CHYBA: {e}")
        sys.exit(1)

    time.sleep(0.3)

    print("\n[PRE] Cistim UART sticky errors...")
    ok = uart_clear_errors(ser)
    print(f"  ERR_CLR write: {'OK' if ok else 'TIMEOUT'}")

    pass_count = 0
    fail_count = 0
    zero_bytes = 0
    partial    = 0

    for slot, addr, name in SLOTS:
        for i in range(repeat):
            tag = f"Slot {slot} ({name}) @ 0x{addr:08X}  [#{i+1}]"
            print(f"\n{tag}")
            pkt = make_read_pkt(addr)
            raw = transact(ser, pkt, EXPECTED_READ)

            n = len(raw)
            if n == EXPECTED_READ and raw[0] == SOP_RESP:
                pass_count += 1
            else:
                fail_count += 1
                if n == 0:
                    zero_bytes += 1
                elif n < EXPECTED_READ:
                    partial += 1

    print("\n" + "=" * 65)
    print("[POST] UART STATUS register (0xFF010010):")
    status = uart_read_status(ser)
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
            print("  *** FRAME ERROR: nespravny stop bit — TX→RX coupling alebo baud")
        if not (overrun or frame or parity):
            print("  OK — ziadne chyby")

    ser.close()

    total = pass_count + fail_count
    print("\n" + "=" * 65)
    print(f"Vysledok: {pass_count}/{total} OK  ({fail_count} failed)")
    if fail_count > 0:
        print(f"  z toho: 0B={zero_bytes}  partial={partial}  bad_resp={fail_count - zero_bytes - partial}")
    if fail_count == 0:
        print("KOMPLETNY USPECH")
    elif pass_count == 0:
        print("KOMPLETNY VYPADOK — FPGA neodpoveda")
    else:
        pct = pass_count * 100 // total
        print(f"CIASTOCNY USPECH {pct}% — viz diagnostika vyssie")


if __name__ == "__main__":
    main()
