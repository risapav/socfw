from colorama import Fore, Style
from modules.sys_ctrl import SysCtrl
from modules.gpio import GPIOIn, GPIOOut, SevenSeg
from modules.uart_diag import UARTDiag
from modules.sdram_ctrl import SDRAMController

class DynamicScanner:
    """
    Zabezpečuje automatickú detekciu hardvéru v AXI-Lite IO priestore.
    Mapuje ASCII identifikátory z offsetu 0x00 na konkrétne Python triedy.
    """
    # Register nových modulov tu:
    CLASS_MAP = {
        "SYSC": SysCtrl,
        "INP_": GPIOIn,
        "OUT_": GPIOOut,
        "SEG7": SevenSeg,
        "UART": UARTDiag,
        "SDRM": SDRAMController,
        # "PWM_": PWMControl, <-- Takto jednoducho pridáte nový modul
    }

    def __init__(self, bus, base_io=0xFF000000, stride=0x10000, blacklist=None):
        self.bus = bus
        self.base_io = base_io
        self.stride = stride
        self.blacklist = blacklist or []

    def scan(self):
        inventory = {}
        for slot in range(32):
            addr = self.base_io + (slot * self.stride)

            if addr in self.blacklist:
                print(f"  [Slot {slot:X}] {Fore.LIGHTBLACK_EX}SKIP (Blacklisted){Fore.RESET}")
                continue

        for slot in range(32):
            addr = self.base_io + (slot * self.stride)

            # Prečítame COMPONENT_ID (vždy offset 0x0)
            dev_id_raw = self.bus.read32(addr)

            # Detekcia timeoutu zbernice (SYSC watchdog v FPGA vráti 0xEEEEEEEE)
            if dev_id_raw == 0xEEEEEEEE:
                print(f"  [Slot {slot:X}] {Fore.RED}TIMEOUT!{Style.RESET_ALL} Adresa: {hex(addr)}")
                continue

            if dev_id_raw and dev_id_raw != 0:
                try:
                    # Konverzia hex na ASCII (napr. 0x53595343 -> "SYSC")
                    name = dev_id_raw.to_bytes(4, "big").decode("ascii").strip()
                    cls = self.CLASS_MAP.get(name)

                    if cls:
                        # Vytvoríme inštanciu triedy pre daný slot
                        inventory[name] = cls(self.bus, addr, name=name)
                        print(f"  [Slot {slot:X}] {Fore.GREEN}OK{Style.RESET_ALL} - {name} ({cls.__name__})")
                    else:
                        print(f"  [Slot {slot:X}] {Fore.YELLOW}Neznámy ID: {name}{Style.RESET_ALL}")
                except Exception as e:
                    # Chyba dekódovania ASCII (nie je to platné ID)
                    continue

        return inventory
    """

    def scan(self):
        inventory = {}
        print(f"\n{Fore.CYAN}>>> Skenujem AXI-Lite zbernicu (Base: {hex(self.base_io)})...")

        for slot in range(16):
            addr = self.base_io + (slot * self.stride)
            raw = self.bus.read32(addr)
            # Toto ti povie, či Interconnect vôbec žije
            print(f"DEBUG: Slot {slot} @ {hex(addr)} -> Raw: {hex(raw) if raw is not None else 'NONE'}")

            if raw is None: continue # DECERR zasiahol

        for slot in range(16):
            addr = self.base_io + (slot * self.stride)

            if addr in self.blacklist:
                print(f"  [{Fore.LIGHTBLACK_EX}Slot {slot:X}{Fore.RESET}] SKIP (Blacklisted)")
                continue

            # Čítanie ID
            dev_id_raw = self.bus.read32(addr)

            # DEBUG: Odkomentuj tento riadok, ak chceš vidieť, čo presne UART číta
            # print(f" DEBUG Slot {slot:X} @ {hex(addr)} -> {hex(dev_id_raw) if dev_id_raw else 'None'}")

            if dev_id_raw is None:
                # Interconnect vrátil DECERR - slot je prázdny, ideme ďalej
                continue

            if dev_id_raw == 0 or dev_id_raw == 0xFFFFFFFF or dev_id_raw == 0xEEEEEEEE:
                continue

            try:
                name = dev_id_raw.to_bytes(4, "big").decode("ascii").strip()
                cls = self.CLASS_MAP.get(name)

                if cls:
                    inventory[name] = cls(self.bus, addr, name=name)
                    print(f"  [{Fore.GREEN}Slot {slot:X}{Fore.RESET}] OK - {name}")
                else:
                    print(f"  [{Fore.YELLOW}Slot {slot:X}{Fore.RESET}] Neznáme ID: {name}")
            except:
                continue

        return inventory
    """