import socket
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

    @property
    def is_open(self) -> bool:
        return self._ser is not None and self._ser.is_open

    @property
    def baudrate(self) -> int:
        return self._baudrate

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
        """Scan for SOP_RESP (0xFD), then read the rest of the packet."""
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
        time.sleep(self._timeouts.recovery_s)
        self.flush_rx()

    def set_baudrate(self, baudrate: int) -> None:
        self._baudrate = baudrate
        if self._ser and self._ser.is_open:
            self._ser.baudrate = baudrate
            time.sleep(0.05)
            self._ser.reset_input_buffer()


class UdpTransport:
    """XFCP transport over UDP/IPv4.

    Sends raw XFCP request bytes as a UDP datagram and receives the XFCP
    response as a single UDP datagram.  No framing needed — each datagram
    is exactly one XFCP packet.
    """

    def __init__(self, host: str, port: int = 50000, timeouts: XfcpTimeouts = None):
        self._host     = host
        self._port     = port
        self._timeouts = timeouts or XfcpTimeouts()
        self._sock: socket.socket | None = None

    def __enter__(self):
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.settimeout(self._timeouts.udp_s)
        return self

    def __exit__(self, *_):
        if self._sock:
            self._sock.close()
            self._sock = None

    @property
    def is_open(self) -> bool:
        return self._sock is not None

    def flush_rx(self) -> None:
        if not self._sock:
            return
        self._sock.settimeout(0)
        try:
            while True:
                self._sock.recvfrom(2048)
        except (socket.timeout, BlockingIOError, OSError):
            pass
        finally:
            self._sock.settimeout(self._timeouts.udp_s)

    def write(self, data: bytes) -> None:
        try:
            self._sock.sendto(data, (self._host, self._port))
        except OSError as e:
            raise XfcpError(f"UDP send error to {self._host}:{self._port}: {e}") from e

    def read_packet(self, expected_len: int) -> bytes:
        """Receive one UDP datagram; verify it starts with SOP_RESP (0xFD)."""
        from . import protocol as proto
        try:
            data, _ = self._sock.recvfrom(2048)
        except socket.timeout:
            return b""
        except OSError as e:
            raise XfcpError(f"UDP recv error: {e}") from e
        if not data or data[0] != proto.SOP_RESP:
            return b""
        return bytes(data)

    def drain(self) -> None:
        time.sleep(self._timeouts.recovery_s)
        self.flush_rx()

    def set_baudrate(self, _: int) -> None:
        pass  # not applicable to UDP
