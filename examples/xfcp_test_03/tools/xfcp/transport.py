import time
import serial

from .errors import XfcpError
from .timeouts import XfcpTimeouts


class SerialTransport:
    def __init__(self, port: str, baudrate: int = 115200, timeouts: XfcpTimeouts = None):
        self._port      = port
        self._baudrate  = baudrate
        self._timeouts  = timeouts or XfcpTimeouts()
        self._ser: serial.Serial | None = None

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------

    def __enter__(self):
        try:
            self._ser = serial.Serial(
                self._port,
                self._baudrate,
                timeout=self._timeouts.response_s,
            )
        except serial.SerialException as e:
            raise XfcpError(f"Cannot open {self._port}: {e}") from e
        self._ser.reset_input_buffer()
        return self

    def __exit__(self, *_):
        if self._ser and self._ser.is_open:
            self._ser.close()

    # ------------------------------------------------------------------
    # Low-level I/O
    # ------------------------------------------------------------------

    @property
    def is_open(self) -> bool:
        return self._ser is not None and self._ser.is_open

    def flush_rx(self) -> None:
        if self._ser:
            self._ser.reset_input_buffer()

    def write(self, data: bytes) -> None:
        try:
            self._ser.write(data)
        except serial.SerialException as e:
            raise XfcpError(f"Serial write error: {e}") from e

    def read(self, n: int) -> bytes:
        try:
            return self._ser.read(n)
        except serial.SerialException as e:
            raise XfcpError(f"Serial read error: {e}") from e

    def read_packet(self, expected_len: int) -> bytes:
        """Read one XFCP response packet, scanning for SOP_RESP (0xFD) first.

        Discards any stale bytes that arrive before the SOP_RESP byte, then
        reads the remaining (expected_len - 1) bytes. Returns the complete
        packet as bytes, or a partial buffer on timeout.
        """
        from . import protocol as proto
        deadline = time.monotonic() + self._timeouts.response_s
        try:
            while time.monotonic() < deadline:
                b = self._ser.read(1)
                if not b:
                    continue
                if b[0] != proto.SOP_RESP:
                    continue
                buf = bytearray(b)
                remaining = expected_len - 1
                while remaining > 0 and time.monotonic() < deadline:
                    chunk = self._ser.read(remaining)
                    if not chunk:
                        continue
                    buf.extend(chunk)
                    remaining -= len(chunk)
                return bytes(buf)
        except serial.SerialException as e:
            raise XfcpError(f"Serial read error: {e}") from e
        return b""

    def drain(self) -> None:
        """Drain any stale bytes after a failed transaction."""
        time.sleep(self._timeouts.recovery_s)
        self.flush_rx()
