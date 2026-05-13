from core.peripheral import BasePeripheral
from core.register import AxilRegister

class SysCtrl(BasePeripheral):
    """
    Systémový kontrolér (v4.1) - Správa zdravia SoC a diagnostika zbernice.
    """
    # MAPOVANIE REGISTROV (Offsety podľa axil_sys_ctrl.sv)

    # 0x00 [RO] : COMPONENT_ID - Identifikácia modulu (default: "SYSC")
    device_id    = AxilRegister(0x00, doc="ASCII ID modulu")

    # 0x04 [RO] : HW_STATUS - Stavové bity
    pll_locked   = AxilRegister(0x04, bit_offset=0, bit_width=1, doc="PLL Lock Status")
    ic_timeout   = AxilRegister(0x04, bit_offset=3, bit_width=1, doc="Interconnect Timeout")

    # 0x08 [Pulse]: CONTROL - Riadiace impulzy (Write-only v podstate)
    sw_reset     = AxilRegister(0x08, bit_offset=0, bit_width=1, readonly=False)
    clear_faults = AxilRegister(0x08, bit_offset=2, bit_width=1, readonly=False)

    # 0x0C [RO] : UPTIME - Sekundy od resetu
    uptime       = AxilRegister(0x0C, doc="Uptime v sekundách")

    # 0x10 [RO] : FAULT_ADDR - Posledná adresa, ktorá spôsobila AXI Timeout
    fault_addr   = AxilRegister(0x10)

    # 0x14 [RO] : FAULT_STATUS - Bitmapa vinníkov
    fault_status = AxilRegister(0x14)

    def get_live_metrics(self):
        """Vráti dáta pre rýchly monitoring."""
        return {
            "uptime": f"{self.uptime}s",
            "pll": "OK" if self.pll_locked else "FAIL",
            "bus_err": "!!!" if self.ic_timeout else "OK"
        }

    def heal_bus(self):
        """Vykoná záchrannú operáciu pri záseku."""
        if self.ic_timeout:
            print(f"DEBUG: Resetujem chybu na adrese {hex(self.fault_addr)}")
            self.clear_faults = 1