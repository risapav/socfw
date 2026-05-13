# core/peripheral.py

class BasePeripheral:
    """Základná trieda pre všetky AXI-Lite periférie."""
    def __init__(self, bus, base_addr, name="UNKNOWN"):
        self.bus = bus
        self.base = base_addr
        self.name = name

    def read32(self, offset):
        """Základná metóda pre čítanie cez zbernicu."""
        return self.bus.read32(self.base + offset)

    def write32(self, offset, val):
        """Základná metóda pre zápis cez zbernicu."""
        return self.bus.write32(self.base + offset, val)

    def get_live_metrics(self):
        """Metóda, ktorú prepíšu moduly pre potreby monitoringu."""
        return {}

    def run_test(self):
        """Defaultná implementácia, ak modul nemá špecifický test."""
        print(f"  [!] Modul {self.name} nepodporuje automatizovaný test.")
        return True