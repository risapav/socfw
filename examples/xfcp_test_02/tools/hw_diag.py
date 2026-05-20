#!/usr/bin/env python3
"""
hw_diag.py — Minimálny HW diagnostický skript pre xfcp_test_02.

Posiela 1 READ na každý slot (0xFF000000–0xFF050000) a vypisuje
RAW hex bajtov. Nevyužíva žiadnu abstrakciu – priamy serial.Serial.

Cieľ: zistiť či FPGA vôbec posiela NEJAKÉ bajty (aj čiastočné).

Výsledok interpretovania:
  25 bajtov → RESP_READ (správne)
  21 bajtov → RESP_WRITE (engine timeout na FPGA strane)
   0 bajtov → FPGA neodosiela nič (arbiter/parser deadlock, UART TX stuck)
   N bajtov → čiastočná odpoveď (TX preruší uprostred)
"""

import serial
import struct
import time
import sys

PORT    = '/dev/ttyUSB0'
BAUD    = 115200
TIMEOUT = 5.0    # generous timeout — ak FPGA nieco posiela, dostaneme to

SOP      = 0xFE
OP_READ  = 0x10

SLOTS = [
    (0, 0xFF000000, "SYSC"),
    (1, 0xFF010000, "UART"),
    (2, 0xFF020000, "LED0"),
    (3, 0xFF030000, "LED1"),
    (4, 0xFF040000, "LED2"),
    (5, 0xFF050000, "SEG7"),
]

EXPECTED_READ = 25   # SOP(1)+TYPE(1)+DEV_TYPE(2)+DEV_STR(16)+DATA(4)+TERM(1)

def make_read_pkt(addr):
    return bytes([SOP, OP_READ, 0x00, 0x04]) + struct.pack(">I", addr)

def decode_resp(raw):
    if len(raw) == 0:
        return "0 bajtov — FPGA NEODPOVEDAL"
    lines = [f"  {len(raw)} bajtov: {raw.hex(' ')}"]
    if len(raw) >= 2:
        lines.append(f"  SOP=0x{raw[0]:02X}  TYPE=0x{raw[1]:02X}", )
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

def main():
    port = sys.argv[1] if len(sys.argv) > 1 else PORT
    print(f"Otváram {port} @ {BAUD} baud, timeout={TIMEOUT}s")
    print("=" * 60)

    try:
        ser = serial.Serial(port, BAUD, timeout=TIMEOUT)
    except Exception as e:
        print(f"CHYBA: {e}")
        sys.exit(1)

    time.sleep(0.2)   # nechaj port stabilizovat

    for slot, addr, name in SLOTS:
        pkt = make_read_pkt(addr)
        print(f"\nSlot {slot} ({name}) @ 0x{addr:08X}")
        print(f"  Odosielam: {pkt.hex(' ')}")

        ser.reset_input_buffer()
        t0 = time.time()
        ser.write(pkt)
        # Citame az 40 bajtov — ak FPGA posle viac (napr. 2 pakety), chceme vediet
        raw = ser.read(40)
        elapsed = time.time() - t0

        print(f"  Cas: {elapsed*1000:.1f} ms")
        print(decode_resp(raw))

        # Druha skusa po 200ms (overenie ci je to opakovatelne)
        time.sleep(0.2)
        ser.reset_input_buffer()
        t0 = time.time()
        ser.write(pkt)
        raw2 = ser.read(40)
        elapsed2 = time.time() - t0
        print(f"  [Retry] Cas: {elapsed2*1000:.1f} ms")
        print(decode_resp(raw2).replace("  ", "    "))

    ser.close()
    print("\n" + "=" * 60)
    print("Diagnostika hotova.")

if __name__ == "__main__":
    main()
