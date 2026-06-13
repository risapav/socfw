from core.peripheral import BasePeripheral
from core.register import AxilRegister
from colorama import Fore


class DiagCtrl(BasePeripheral):
    """DIAG -- UART diagnostic counter peripheral (axil_diag_ctrl).

    All counters are 32-bit saturating and read from shadow registers.
    Use snapshot() to freeze live counters into shadow before reading.
    Use reset_counters() to clear everything.
    """

    device_id      = AxilRegister(0x00, doc="ASCII ID ('DIAG')")

    rx_seen        = AxilRegister(0x04, doc="UART RX bytes seen (pre-FIFO)")
    rx_accept      = AxilRegister(0x08, doc="RX bytes accepted into FIFO")
    rx_lost        = AxilRegister(0x0C, doc="RX bytes lost (FIFO full)")
    rx_frame       = AxilRegister(0x10, doc="Frame error count")
    rx_overrun     = AxilRegister(0x14, doc="Overrun error count")
    rx_sop         = AxilRegister(0x18, doc="Good SOP count")
    rx_hdr         = AxilRegister(0x1C, doc="Parsed header count")
    rx_bad_hdr     = AxilRegister(0x20, doc="Bad header / decode error count")
    rx_recovery    = AxilRegister(0x24, doc="SOP recovery event count")
    rx_drop        = AxilRegister(0x28, doc="Parser drop count")
    fab_req        = AxilRegister(0x2C, doc="Fabric requests dispatched")
    fab_resp       = AxilRegister(0x30, doc="Fabric responses sent")
    tx_byte        = AxilRegister(0x34, doc="UART TX bytes sent")
    tx_pkt         = AxilRegister(0x38, doc="TX packets started")

    diag_reset     = AxilRegister(0x3C, readonly=False, doc="PULSE: clear all counters")
    diag_snapshot  = AxilRegister(0x40, readonly=False, doc="PULSE: snapshot live->shadow")

    def snapshot(self):
        """Freeze live counters into shadow registers."""
        self.diag_snapshot = 1

    def reset_counters(self):
        """Clear all live and shadow counters."""
        self.diag_reset = 1

    def get_live_metrics(self):
        self.snapshot()
        return {
            "rx_ok":  str(self.rx_accept),
            "rx_sop": str(self.rx_sop),
            "tx_pkt": str(self.tx_pkt),
            "drop":   str(self.rx_drop),
        }

    def run_test(self):
        print(f"  [DIAG] Snapshot...")
        self.snapshot()
        print(f"    rx_seen={self.rx_seen}  rx_accept={self.rx_accept}  "
              f"rx_lost={self.rx_lost}")
        print(f"    rx_sop={self.rx_sop}  rx_hdr={self.rx_hdr}  "
              f"rx_bad_hdr={self.rx_bad_hdr}  rx_drop={self.rx_drop}")
        print(f"    fab_req={self.fab_req}  fab_resp={self.fab_resp}")
        print(f"    tx_byte={self.tx_byte}  tx_pkt={self.tx_pkt}")
        errs = self.rx_frame + self.rx_overrun + self.rx_bad_hdr + self.rx_drop
        if errs:
            print(f"  {Fore.YELLOW}[DIAG] Varování: {errs} chýb detekovaných.{Fore.RESET}")
        else:
            print(f"  {Fore.GREEN}[DIAG] Bez chýb.{Fore.RESET}")
        return True
