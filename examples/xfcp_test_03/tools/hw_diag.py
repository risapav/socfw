#!/usr/bin/env python3
"""
hw_diag.py — Minimálny HW diagnostický skript pre xfcp_test_03.

Posiela READ na každý slot (0xFF000000–0xFF050000) a vypisuje
RAW hex bajtov. Nevyužíva žiadnu abstrakciu – priamy serial.Serial.

Na záver: vyčistí UART sticky errors pred testom, po teste prečíta
STATUS register a overí či prišli overrun/frame chyby (TX→RX coupling test).

Výsledok interpretovania:
  25 bajtov → RESP_READ (správne)
   0 bajtov → FPGA neodosiela nič (arbiter deadlock, TX stuck)
   N bajtov → čiastočná odpoveď
"""

import serial
import struct
import time
import sys

PORT    = '/dev/ttyUSB0'
BAUD    = 115200
TIMEOUT = 2.0

SOP      = 0xFE
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
UART_ERR_CLR = UART_BASE + 0x0C   # PULSE: bit 0 = clear sticky errors
UART_STATUS  = UART_BASE + 0x10   # RO: [2]=overrun [3]=frame [4]=parity


def make_read_pkt(addr):
    return bytes([SOP, OP_READ, 0x00, 0x04]) + struct.pack(">I", addr)


def make_write_pkt(addr, val):
    return bytes([SOP, OP_WRITE, 0x00, 0x04]) + struct.pack(">I", addr) + struct.pack(">I", val)


def decode_resp(raw):
    if len(raw) == 0:
        return "  0 bajtov — FPGA NEODPOVEDAL"
    lines = [f"  {len(raw)} bajtov: {raw.hex(' ')}"]
    if len(raw) >= 2:
        lines.append(f"  SOP=0x{raw[0]:02X}  TYPE=0x{raw[1]:02X}")
    if len(raw) >= 4:
        dev_type = struct.unpack(">H", raw[2:4])[0]
        lines.append(f"  DEV_TYPE=0x{dev_type:04X}")
    if len(raw) >= 20:
        dev_str = raw[4:20]
        try:
            lines.append(f"  DEV_STR='{dev_str.decode('ascii')}'")
        except Exception:
            lines.append(f"  DEV_STR (hex)={dev_str.hex()}")
    if len(raw) == EXPECTED_READ:
        data = struct.unpack(">I", raw[20:24])[0]
        lines.append(f"  DATA=0x{data:08X}  ('{chr((data>>24)&0xFF)}{chr((data>>16)&0xFF)}{chr((data>>8)&0xFF)}{chr(data&0xFF)}')")
    return "\n".join(lines)


def transact_read(ser, addr, label):
    pkt = make_read_pkt(addr)
    print(f"  Odosielam: {pkt.hex(' ')}")
    ser.reset_input_buffer()
    t0 = time.time()
    ser.write(pkt)
    raw = ser.read(EXPECTED_READ)
    elapsed = time.time() - t0
    print(f"  Čas: {elapsed*1000:.1f} ms")
    print(decode_resp(raw))
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
    print(f"Otváram {port} @ {BAUD} baud, timeout={TIMEOUT}s")
    print("=" * 60)

    try:
        ser = serial.Serial(port, BAUD, timeout=TIMEOUT)
    except Exception as e:
        print(f"CHYBA: {e}")
        sys.exit(1)

    time.sleep(0.2)

    # --- Vyčistenie UART sticky chýb pred testom ---
    print("\n[PRE] Čistím UART sticky errors...")
    ok = uart_clear_errors(ser)
    print(f"  ERR_CLR write: {'OK' if ok else 'TIMEOUT'}")

    pass_count = 0
    fail_count = 0

    for slot, addr, name in SLOTS:
        print(f"\nSlot {slot} ({name}) @ 0x{addr:08X}")
        raw = transact_read(ser, addr, name)
        if len(raw) == EXPECTED_READ:
            pass_count += 1
        else:
            fail_count += 1

        # Retry po 200ms
        time.sleep(0.2)
        print(f"  [Retry]")
        raw2 = transact_read(ser, addr, name)
        if len(raw2) == EXPECTED_READ:
            pass_count += 1
        else:
            fail_count += 1

    # --- Stav po teste: UART STATUS register ---
    print("\n" + "=" * 60)
    print("[POST] UART STATUS register (0xFF010010):")
    status = uart_read_status(ser)
    if status is None:
        print("  TIMEOUT — FPGA neodpovedal ani na STATUS read")
    else:
        tx_busy  = bool(status & 0x01)
        rx_busy  = bool(status & 0x02)
        overrun  = bool(status & 0x04)
        frame    = bool(status & 0x08)
        parity   = bool(status & 0x10)
        print(f"  RAW=0x{status:08X}")
        print(f"  tx_busy={tx_busy}  rx_busy={rx_busy}")
        print(f"  overrun={overrun}  frame={frame}  parity={parity}")
        if overrun:
            print("  *** OVERRUN: UART RX prijímal bajty rýchlejšie ako parser čítal")
            print("  *** Možná príčina: TX→RX coupling (FPGA TX bajty dosahujú FPGA RX)")
        if frame:
            print("  *** FRAME ERROR: nesprávny stop bit — overreň baud rate alebo signál")
        if not (overrun or frame or parity):
            print("  OK — žiadne chyby, žiadny TX→RX coupling")

    ser.close()
    print("\n" + "=" * 60)
    total = pass_count + fail_count
    print(f"Výsledok: {pass_count}/{total} OK  ({fail_count} timeoutov)")
    if fail_count == 0:
        print("KOMPLETNÝ ÚSPECH — HW bug opravený!")
    elif pass_count == 0:
        print("KOMPLETNÝ VÝPADOK — FPGA neodpovedá")
    else:
        print(f"ČIASTOČNÝ ÚSPECH — overuj STATUS chyby vyššie")


if __name__ == "__main__":
    main()
