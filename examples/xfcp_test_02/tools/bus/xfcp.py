import serial
import struct


class XFCPBus:
    """
    Low-level driver for XFCP (SOP=0xFE) over UART.

    Request format  : SOP(0xFE) | OPCODE | COUNT[15:8] | COUNT[7:0]
                      | ADDR[31:24] | ADDR[23:16] | ADDR[15:8] | ADDR[7:0]
                      | [PAYLOAD bytes for WRITE, MSB-first]

    Response format : SOP(0xFE) | TYPE | DEV_TYPE[15:8] | DEV_TYPE[7:0]
                      | DEV_STR[16 bytes] | [PAYLOAD bytes for READ] | 0x00
      Header size = 20 bytes (1+1+2+16).
      LITTLE_ENDIAN=0 on FPGA side → data is MSB-first (big-endian) on wire.
    """

    RESP_HEADER  = 20   # SOP + TYPE + DEV_TYPE(2) + DEV_STR(16)
    RESP_TRAILER = 1    # terminating 0x00 byte

    OP_READ  = 0x10
    OP_WRITE = 0x11
    OP_RESP_READ  = 0x12
    OP_RESP_WRITE = 0x13
    SOP = 0xFE

    def __init__(self, port='/dev/ttyUSB0', baudrate=115200, timeout=1.0, retries=1):
        self.port     = port
        self.baudrate = baudrate
        self.timeout  = timeout
        self.retries  = retries   # read retries; writes never retry (not idempotent)
        self.ser      = None

    def __enter__(self):
        try:
            self.ser = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
        except serial.SerialException as e:
            raise ConnectionError(f"Nemôžem otvoriť port {self.port}: {e}") from e
        self.ser.reset_input_buffer()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.ser and self.ser.is_open:
            self.ser.close()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _transact(self, pkt, expected_len, retries=None):
        """
        Send pkt, read expected_len bytes back.
        On partial read (timeout): flush stale bytes, then retry up to `retries` times.
        Returns bytes on success, None on all attempts exhausted.
        Raises ConnectionError on serial port failure.
        """
        if retries is None:
            retries = self.retries
        for attempt in range(retries + 1):
            try:
                self.ser.write(pkt)
                resp = self.ser.read(expected_len)
            except serial.SerialException as e:
                raise ConnectionError(f"Sériová chyba: {e}") from e
            if len(resp) == expected_len:
                return resp
            # Partial read — flush stale bytes before retry
            self.ser.reset_input_buffer()
        return None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def read32(self, addr):
        """Read one 32-bit register. Returns int or None on timeout."""
        result = self.read_block(addr, 1)
        return result[0] if result else None

    def read_block(self, addr, num_words):
        """
        Burst read of num_words 32-bit registers starting at addr.
        Returns list of ints or None on error/timeout.
        """
        num_bytes = num_words * 4
        pkt = bytes([self.SOP, self.OP_READ]) \
            + struct.pack(">H", num_bytes) \
            + struct.pack(">I", addr)

        total = self.RESP_HEADER + num_bytes + self.RESP_TRAILER
        resp  = self._transact(pkt, total)

        if resp is None:
            return None
        if resp[0] != self.SOP or resp[1] != self.OP_RESP_READ:
            self.ser.reset_input_buffer()
            return None

        payload = resp[self.RESP_HEADER : self.RESP_HEADER + num_bytes]
        return list(struct.unpack(f">{num_words}I", payload))

    def write32(self, addr, val):
        """
        Write one 32-bit value to addr.
        Returns True on ACK, False on error/timeout.
        Writes are not retried — re-sending a pulse register would trigger it twice.
        """
        pkt = bytes([self.SOP, self.OP_WRITE]) \
            + struct.pack(">H", 4) \
            + struct.pack(">I", addr) \
            + struct.pack(">I", val)

        total = self.RESP_HEADER + self.RESP_TRAILER
        resp  = self._transact(pkt, total, retries=0)

        if resp is None:
            return False
        if resp[0] != self.SOP or resp[1] != self.OP_RESP_WRITE:
            self.ser.reset_input_buffer()
            return False
        return True
