from core.peripheral import BasePeripheral
from core.register import AxilRegister
from colorama import Fore

class UARTDiag(BasePeripheral):
    """
    UART IP jadro (v3.1) s diagnostikou FIFO a konfiguráciou Baudrate.
    Umožňuje sledovať vyťaženie linky a detegovať chyby prenosu (frame, parity, overrun).
    """

    # 0x00 [RO] : COMPONENT_ID
    id_val      = AxilRegister(0x00, doc="ASCII ID modulu (UART)")

    # 0x04 [RW] : BAUD_RATE - Prescale hodnota
    baud_pre    = AxilRegister(0x04, readonly=False, doc="Baudrate prescaler value")

    # 0x08 [RW] : CONFIG - [1:0] Data bits, [2] Parity En, [3] Odd, [4] Stop2
    data_bits   = AxilRegister(0x08, bit_offset=0, bit_width=2, readonly=False)
    parity_en   = AxilRegister(0x08, bit_offset=2, bit_width=1, readonly=False)
    parity_odd  = AxilRegister(0x08, bit_offset=3, bit_width=1, readonly=False)
    stop2_en    = AxilRegister(0x08, bit_offset=4, bit_width=1, readonly=False)

    # 0x0C [PULSE]: ERR_CLR - [0] Vymazanie stavových chýb
    clear_errors = AxilRegister(0x0C, bit_offset=0, bit_width=1, readonly=False)

    # 0x10 [RO] : STATUS - [0] TX Busy, [1] RX Busy, [2] Overrun, [3] Frame, [4] Parity Err
    tx_busy     = AxilRegister(0x10, bit_offset=0, bit_width=1)
    rx_busy     = AxilRegister(0x10, bit_offset=1, bit_width=1)
    err_overrun = AxilRegister(0x10, bit_offset=2, bit_width=1)
    err_frame   = AxilRegister(0x10, bit_offset=3, bit_width=1)
    err_parity  = AxilRegister(0x10, bit_offset=4, bit_width=1)

    # 0x14 [RO] : TX_FIFO_CNT - Počet bytov v TX FIFO
    tx_fifo_cnt = AxilRegister(0x14, doc="Current bytes in TX FIFO")

    # 0x18 [RO] : RX_FIFO_CNT - Počet bytov v RX FIFO
    rx_fifo_cnt = AxilRegister(0x18, doc="Current bytes in RX FIFO")

    def configure(self, prescaler, data_bits=8, parity=None, stop2=False):
        """Pomocná metóda na nastavenie UART parametrov naraz."""
        dbits_map = {8: 0b00, 7: 0b01, 6: 0b10, 5: 0b11}
        if data_bits not in dbits_map:
            raise ValueError("data_bits must be one of: 8, 7, 6, 5")
        self.baud_pre = prescaler
        self.data_bits = dbits_map[data_bits]
        self.parity_en = 1 if parity else 0
        if parity:
            self.parity_odd = 1 if parity == 'odd' else 0
        self.stop2_en = 1 if stop2 else 0

    def get_live_metrics(self):
        """Metóda pre Dynamic Monitor - optimalizované čítanie stavu."""
        # Prečítame stav a FIFO registre naraz (offset 0x10 až 0x18)
        data = self.bus.read_block(self.base + 0x10, 3)
        if not data: return {"UART": "N/A"}

        status = data[0]
        tx_cnt = data[1]
        rx_cnt = data[2]

        # Detekcia akejkoľvek chyby
        has_error = bool(status & 0x1C) # Overrun, Frame, Parity bity
        err_str = f"{Fore.RED}ERR!{Fore.RESET}" if has_error else "OK"

        return {
            "stat": err_str,
            "tx_f": tx_cnt,
            "rx_f": rx_cnt,
            "busy": "TX" if (status & 1) else ("RX" if (status & 2) else "IDLE")
        }

    def run_test(self):
        print(f"  [UART] Kontrola FIFO stavu...", end=" ", flush=True)
        self.clear_errors = 1
        if self.tx_fifo_cnt == 0 and self.rx_fifo_cnt == 0:
            print(f"{Fore.GREEN}OK (Empty){Fore.RESET}")
            return True
        print(f"{Fore.YELLOW}Zistené dáta v FIFO{Fore.RESET}")
        return True