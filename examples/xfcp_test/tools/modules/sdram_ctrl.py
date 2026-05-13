from core.peripheral import BasePeripheral
from core.register import AxilRegister
from colorama import Fore

class SDRAMController(BasePeripheral):
    """
    Ovládač pre SDRAM adaptér s diagnostikou Probe Bus.
    """
    # --- Registre ---
    # Register 0x00 je ID (zdedené z BasePeripheral ako component_id_reg)

class SDRAMController(BasePeripheral):
    """Diagnostika SDRAM cez Shadow rozsah (Slot E)."""

    # 0x0C: diag_ctrl (Injektované v RTL: PLL, Ready, FSM)
    # 0x10: diag_bridge (Injektované v RTL: Refresh, Busy)
    status_reg = AxilRegister(0x0C, readonly=True)
    bridge_reg = AxilRegister(0x10, readonly=True)

    def get_live_metrics(self):
        val = self.status_reg
        if val is None:
            return {"status": f"{Fore.RED}OFFLINE{Fore.RESET}"}

        pll_ok = bool(val & (1 << 31))
        ready  = bool(val & (1 << 30))
        fsm    = val & 0x3F

        state = f"{Fore.GREEN}READY" if ready else f"{Fore.YELLOW}INIT"
        if not pll_ok: state = f"{Fore.RED}NOPLL"

        return {
            "ST": state,
            "FSM": f"0x{fsm:02X}"
        }

    def run_test(self):
        """Integrovaný test integrity SDRAM."""
        print(f"\n{Fore.YELLOW}>>> TEST SDRAM @ {hex(self.base)}")

        if not self.pll_locked:
            print(f"  [{Fore.RED}FAIL{Fore.RESET}] PLL nie je uzamknutý!")
            return False

        # Skúsime základný zápis a čítanie cez XFCP na adresu 0x0000_0000
        # Pozor: Adresa 0 je začiatok RAM_SIZE v Interconnecti
        test_addr = 0x00000000
        test_pattern = 0xAA55BCDE

        print(f"  [*] Zápis vzoru {hex(test_pattern)} na adresu {hex(test_addr)}...")
        self.bus.write32(test_addr, test_pattern)

        readback = self.bus.read32(test_addr)
        if readback == test_pattern:
            print(f"  [{Fore.GREEN}PASS{Fore.RESET}] SDRAM Data Path OK.")
            return True
        else:
            print(f"  [{Fore.RED}FAIL{Fore.RESET}] Mismatch! Prečítané: {hex(readback if readback else 0)}")
            return False