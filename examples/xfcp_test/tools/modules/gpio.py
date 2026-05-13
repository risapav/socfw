import time
from core.peripheral import BasePeripheral
from core.register import AxilRegister
from colorama import Fore, Style

class GPIOIn(BasePeripheral):
    """
    Vstupný modul (INP_) s podporou Edge Capture (v zachytenie hrán).

    MAPOVANIE REGISTROV (Offsety):
    0x00 [RO] : COMPONENT_ID - ASCII "INP_"
    0x04 [RO] : DATA_REG     - Aktuálny stav fyzických pinov (tlačidlá, prepínače)
    0x08 [RW] : EDGE_REG     - Príznak zachytenej hrany. Zápisom 1 sa príznak vymaže (PULSE).
    """

    # Register 0x00 je spoločný (COMPONENT_ID)
    id_val    = AxilRegister(0x00, doc="ASCII ID modulu")

    # Register 0x04: Okamžitý stav vstupov
    # Predpokladáme 8-bitové vstupy, zvyšok 32-bitového slova je rezervovaný
    data      = AxilRegister(0x04, bit_width=8, doc="Okamžitý stav vstupov")

    # Register 0x08: Zachytené hrany
    # V RTL je tento register typu 'sticky' - vyžaduje zápis pre vymazanie
    edges     = AxilRegister(0x08, bit_width=8, readonly=False, doc="Zachytené nábežné hrany")

    def clear_all_edges(self):
        """Vymaže všetky zachytené hrany zápisom logickej 1 do všetkých bitov registra."""
        self.edges = 0xFF

    def get_live_metrics(self):
        """Metóda pre Dynamic Monitor."""
        return {
            "val": f"0x{self.data:02X}",
            "edge": f"0x{self.edges:02X}" if self.edges > 0 else "--"
        }


class GPIOOut(BasePeripheral):
    """
    Výstupný modul (OUT_) pre LED alebo riadiace signály.
    Umožňuje zápis aj spätné čítanie (Read-back) nastavenej hodnoty.

    MAPOVANIE REGISTROV (Offsety):
    0x00 [RO] : COMPONENT_ID - ASCII "OUT_"
    0x04 [RW] : DATA_REG     - Dáta pre fyzické výstupy.
    """

    id_val    = AxilRegister(0x00, doc="ASCII ID modulu")

    # Register 0x04: Dáta pre výstupy
    # Podporuje RW operácie - Python deskriptor automaticky robí Read-Modify-Write
    state     = AxilRegister(0x04, bit_width=32, readonly=False, doc="Stav výstupných pinov")

    def toggle(self, bit_index):
        """XOR operácia nad konkrétnym bitom bez ovplyvnenia ostatných."""
        current = self.state
        self.state = current ^ (1 << bit_index)

    def get_live_metrics(self):
        """Metóda pre Dynamic Monitor."""
        return {
            "out": f"0x{self.state:08X}"
        }

    def run_test(self):
        print(f"  [OUT_] Test bežiaceho svetla...", end=" ", flush=True)
        for i in range(8):
            self.state = (1 << i)
            time.sleep(0.05)
        self.state = 0
        print(f"{Fore.GREEN}OK{Fore.RESET}")
        return True

class SevenSeg(BasePeripheral):
    """
    Adaptér pre 7-segmentový displej (v3.0).
    Formát registra 0x04: [Dot(bit 4), Hex(bits 3:0)] na každý digit.

    MAPOVANIE REGISTROV:
    0x00 [RO] : COMPONENT_ID - ASCII "SEG7"
    0x04 [RW] : DATA_REG     - Packed formát pre 4 digity (každý po 5 bitov).
    """

    # Definujeme jednotlivé digity ako samostatné registre na tom istom offsete 0x04
    digit0 = AxilRegister(0x04, bit_offset=0,  bit_width=5, readonly=False)
    digit1 = AxilRegister(0x04, bit_offset=5,  bit_width=5, readonly=False)
    digit2 = AxilRegister(0x04, bit_offset=10, bit_width=5, readonly=False)
    digit3 = AxilRegister(0x04, bit_offset=15, bit_width=5, readonly=False)

    def set_number(self, val):
        """Rozloží integer na jednotlivé číslice displeja."""
        s_val = str(val).zfill(4)
        try:
            self.digit3 = int(s_val[0], 16)
            self.digit2 = int(s_val[1], 16)
            self.digit1 = int(s_val[2], 16)
            self.digit0 = int(s_val[3], 16)
        except ValueError:
            pass

    def get_live_metrics(self):
        # Ak vieš, že konkrétny kus hardvéru na adrese blbne,
        # pridaj sem try-except alebo kontrolu adresy
        try:
            val = self.read32(0x04)
            if val is None:
                return {"raw": f"{Fore.RED}TIMEOUT{Fore.RESET}"}
            return {"raw": f"0x{val:08X}"}
        except:
            return {"raw": "ERROR"}

    def set_digits_safe(self, values):
        """Zapíše len toľko digitov, koľko hardvér reálne má."""
        packed_val = 0
        for i, v in enumerate(values[:4]): # Max 4 digity
            packed_val |= (int(v) & 0x1F) << (i * 5)
        self.write32(0x04, packed_val)

    def run_test(self):
        print(f"  [SEG7] Testovanie multiplexu (1.2.3.4)...", end=" ", flush=True)
        # Nastavíme "1.2.3.4" (každý digit: bit4=bodka, bity 3:0=hodnota)
        val = (0x11 << 0) | (0x12 << 5) | (0x13 << 10) | (0x14 << 15)
        self.bus.write32(self.base + 0x04, val)
        time.sleep(1)
        print(f"{Fore.GREEN}1. OK{Fore.RESET}")
        """
        self.bus.write32.write32(self.base + 0x04, 0x1234)
        time.sleep(1)
        print(f"{Fore.GREEN}2. OK{Fore.RESET}")

        self.bus.write32.write32(self.base + 0x04, 0x2010)
        time.sleep(1)
        print(f"{Fore.GREEN}3. OK{Fore.RESET}")

        self.bus.write32.write32(self.base + 0x04, 0x123) # Zobrazí "123"
        time.sleep(1)
        print(f"{Fore.GREEN}4. OK{Fore.RESET}")

        self.bus.write32.write32(self.base + 0x04, 0x777)
        time.sleep(1)
        print(f"{Fore.GREEN}5. OK{Fore.RESET}")

        self.bus.write32.write32(self.base + 0x04, 0xFFFFFFFF)
        time.sleep(1)
        print(f"{Fore.GREEN}5. OK{Fore.RESET}")
        """

        #self.set_digits_safe(0x123)
        #self.bus.write32(self.base + 0x04, 0x2010)
        #self.bus.write32(self.base + 0x04, 0x777)
        self.write32(0x04, 0x777)
        print(f"{Fore.GREEN}5. {hex(self.digit3)} {hex(self.digit2)} {hex(self.digit1)} {hex(self.digit0)} OK{Fore.RESET}")
        return True