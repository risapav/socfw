import time
from colorama import Fore, Style
from modules.sys_ctrl import SysCtrl
from modules.gpio import GPIOIn, GPIOOut, SevenSeg
from modules.uart_diag import UARTDiag
from modules.diag_ctrl import DiagCtrl


class DynamicScanner:
    """Auto-detects AXI-Lite peripherals by reading COMPONENT_ID (offset 0x00)."""

    CLASS_MAP = {
        "SYSC": SysCtrl,
        "UART": UARTDiag,
        "OUT_": GPIOOut,
        "SEG7": SevenSeg,
        "INP_": GPIOIn,
        "DIAG": DiagCtrl,
    }

    def __init__(self, bus, base_io=0xFF000000, stride=0x10000,
                 num_slots=7, blacklist=None, slot_retries=2):
        self.bus          = bus
        self.base_io      = base_io
        self.stride       = stride
        self.num_slots    = num_slots
        self.blacklist    = set(blacklist or [])
        self.slot_retries = slot_retries

    def scan(self):
        inventory = {}
        print(f"\n{Fore.CYAN}>>> Skenujem AXI-Lite zbernicu "
              f"(Base: {hex(self.base_io)}, slots: 0-{self.num_slots - 1})...")

        for slot in range(self.num_slots):
            addr = self.base_io + slot * self.stride

            if addr in self.blacklist:
                print(f"  [Slot {slot}] {Fore.LIGHTBLACK_EX}SKIP{Style.RESET_ALL}")
                continue

            dev_id_raw = self._read_slot(addr)

            if dev_id_raw is None:
                print(f"  [Slot {slot}] {Fore.RED}TIMEOUT{Style.RESET_ALL} "
                      f"@ {hex(addr)}")
                continue

            if dev_id_raw in (0x00000000, 0xFFFFFFFF, 0xEEEEEEEE):
                continue

            try:
                name = dev_id_raw.to_bytes(4, "big").decode("ascii").strip()
                cls  = self.CLASS_MAP.get(name)

                if cls:
                    key = name
                    n = 0
                    while key in inventory:
                        n += 1
                        key = f"{name}{n}"
                    inventory[key] = cls(self.bus, addr, name=key)
                    print(f"  [Slot {slot}] {Fore.GREEN}OK{Style.RESET_ALL} "
                          f"- {key} ({cls.__name__}) @ {hex(addr)}")
                else:
                    print(f"  [Slot {slot}] {Fore.YELLOW}Neznáme ID: "
                          f"'{name}'{Style.RESET_ALL} @ {hex(addr)}")
            except (UnicodeDecodeError, ValueError):
                print(f"  [Slot {slot}] {Fore.LIGHTBLACK_EX}non-ASCII "
                      f"({hex(dev_id_raw)}){Style.RESET_ALL}")

        return inventory

    def _read_slot(self, addr):
        for attempt in range(self.slot_retries):
            val = self.bus.read32(addr)
            if val is not None:
                return val
            if attempt < self.slot_retries - 1:
                time.sleep(0.1)
        return None
