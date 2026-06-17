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
    0x04 [RW] : DATA_REG     - Packed formát pre N digitov (každý po 5 bitov).
    """

    # Konfigurácia počtu fyzicky pripojených digitov (dynamicky ovplyvňuje správanie)
    num_digits = 2

    # Abstrakcia pre ID register
    id_val = AxilRegister(0x00, doc="ASCII ID modulu")

    # Definujeme registre pre maximálnu kapacitu (4 digity).
    # Logika nižšie zabezpečí, že sa využijú len tie aktívne.
    digit0 = AxilRegister(0x04, bit_offset=0,  bit_width=5, readonly=False)
    digit1 = AxilRegister(0x04, bit_offset=5,  bit_width=5, readonly=False)
    digit2 = AxilRegister(0x04, bit_offset=10, bit_width=5, readonly=False)
    digit3 = AxilRegister(0x04, bit_offset=15, bit_width=5, readonly=False)

    def set_number(self, val):
        """Rozloží integer na jednotlivé číslice displeja podľa počtu digitov."""
        # Prevedieme na string, orežeme zľava ak je dlhší (napr. 9999 pre 3 digity -> 999),
        # a doplníme nuly ak je kratší (napr. 5 -> 005)
        s_val = str(val).zfill(self.num_digits)[-self.num_digits:]
        try:
            for i in range(self.num_digits):
                # digit0 je úplne vpravo (zodpovedá poslednému znaku stringu)
                val_int = int(s_val[self.num_digits - 1 - i], 16)
                setattr(self, f"digit{i}", val_int)
        except ValueError:
            pass

    def get_live_metrics(self):
        try:
            val = self.read32(0x04)
            if val is None:
                return {"raw": f"{Fore.RED}TIMEOUT{Fore.RESET}"}
            # Voliteľne by sa tu dala pridať maska pre výpis len aktívnych bitov,
            # ale z hľadiska diagnostiky je lepšie vidieť celý HW 32-bit register.
            return {"raw": f"0x{val:08X}"}
        except:
            return {"raw": "ERROR"}

    def set_digits_safe(self, values):
        """Zapíše len toľko digitov, koľko hardvér reálne má (podľa self.num_digits)."""
        packed_val = 0
        for i, v in enumerate(values[:self.num_digits]):
            packed_val |= (int(v) & 0x1F) << (i * 5)
        self.write32(0x04, packed_val)

    def run_test(self):
        """
        Spustí diagnostickú sekvenciu pre overenie funkčnosti 7-segmentového displeja.
        Dynamicky sa prispôsobuje počtu dostupných digitov (self.num_digits).
        """
        print(f"{Fore.CYAN}Spúšťam diagnostiku displeja (Component ID: {self.id_val})...{Fore.RESET}")

        try:
            # 1. TEST: Všetky segmenty a bodky
            print(f"Efekt 1/4: Všetky segmenty a bodky ({self.num_digits} digity)")
            # Vytvorí pole [0x18, 0x18, ...] presne podľa počtu digitov
            self.set_digits_safe([0x18] * self.num_digits)
            time.sleep(1.0)

            # 2. TEST: Rýchle počítanie
            print("Efekt 2/4: Dekadické počítanie")
            # Vygeneruje postupnosť: napr. [0, 111, 222, ... 999] pre 3 digity
            count_seq = [0] + [int(str(x) * self.num_digits) for x in range(1, 10)]
            for i in count_seq:
                self.set_number(i)
                time.sleep(0.15)
            time.sleep(0.5)

            # 3. TEST: Hexadecimálny posun
            print("Efekt 3/4: Hexadecimálny shift (AbCdEF)")
            hex_sequence = [0xA, 0xB, 0xC, 0xD, 0xE, 0xF]
            # Uistíme sa, že sekvencia je dlhšia ako samotný displej
            if len(hex_sequence) >= self.num_digits:
                for i in range(len(hex_sequence) - self.num_digits + 1):
                    # Vytvoríme výsek a otočíme ho (nultý prvok pola sa posiela do digit0)
                    window = hex_sequence[i : i + self.num_digits]
                    self.set_digits_safe(window[::-1])
                    time.sleep(0.4)
            time.sleep(0.5)

            # 4. TEST: Bežiaca bodka
            print("Efekt 4/4: Bežiaca desatinná čiarka")
            for _ in range(2):
                for pos in range(self.num_digits):
                    vals = [0x00] * self.num_digits
                    vals[pos] = 0x10
                    self.set_digits_safe(vals)
                    time.sleep(0.2)

            print(f"{Fore.GREEN}Test dokončený.{Fore.RESET}")

        except Exception as e:
            print(f"{Fore.RED}Chyba počas testu: {e}{Fore.RESET}")

        finally:
            # Upratanie: Zhasnutie displeja
            self.set_digits_safe([0x00] * self.num_digits)

        return True
