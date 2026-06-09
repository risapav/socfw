import time

from .errors import XfcpError, XfcpTimeoutError, XfcpProtocolError, XfcpRecoveryError
from .timeouts import XfcpTimeouts
from .transport import SerialTransport, UdpTransport
from . import protocol as proto

_SYSC_ADDR = 0xFF000000


class XfcpBus:
    """XFCP register-access bus.

    Accepts any transport object that implements the transport protocol
    (write, read_packet, flush_rx, drain, __enter__, __exit__).
    Use the factory functions uart_bus() and udp_bus() for convenience.
    """

    def __init__(self, transport, retries: int = 1):
        self._transport = transport
        self._retries   = retries
        self._seq = 0

    # ------------------------------------------------------------------
    # Factory helpers
    # ------------------------------------------------------------------

    @classmethod
    def uart(cls, port: str = '/dev/ttyUSB0', baudrate: int = 115200,
             timeouts: XfcpTimeouts = None, retries: int = 1):
        return cls(SerialTransport(port, baudrate, timeouts or XfcpTimeouts()), retries)

    @classmethod
    def udp(cls, host: str = '192.168.0.5', port: int = 50000,
            timeouts: XfcpTimeouts = None, retries: int = 1):
        return cls(UdpTransport(host, port, timeouts or XfcpTimeouts()), retries)

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------

    def __enter__(self):
        self._transport.__enter__()
        return self

    def __exit__(self, *args):
        self._transport.__exit__(*args)

    # ------------------------------------------------------------------
    # SEQ counter
    # ------------------------------------------------------------------

    def _next_seq(self) -> int:
        s = self._seq
        self._seq = (self._seq + 1) & 0xFF
        return s

    # ------------------------------------------------------------------
    # Internal transaction engine
    # ------------------------------------------------------------------

    def _transact(self, pkt: bytes, expected: int, retries: int = None) -> bytes:
        if retries is None:
            retries = self._retries
        self._transport.flush_rx()
        resp = b""
        for _ in range(retries + 1):
            self._transport.write(pkt)
            resp = self._transport.read_packet(expected)
            if len(resp) == expected:
                return resp
            self._transport.drain()
        raise XfcpTimeoutError(
            f"No response after {retries + 1} attempt(s): got {len(resp)}/{expected} bytes"
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def ping(self) -> bool:
        try:
            return self.read32(_SYSC_ADDR) is not None
        except XfcpError:
            return False

    def read32(self, addr: int) -> int:
        result = self.read_block(addr, 1)
        return result[0] if result is not None else None

    def write32(self, addr: int, val: int) -> bool:
        seq = self._next_seq()
        pkt = proto.encode_write(addr, [val], seq=seq)
        try:
            raw = self._transact(pkt, proto.resp_len(0, is_write=True), retries=0)
            proto.decode_write_response(raw, expected_seq=seq)
            return True
        except (XfcpTimeoutError, XfcpProtocolError):
            return False

    def read_block(self, addr: int, num_words: int) -> list:
        results   = []
        offset    = 0
        remaining = num_words
        while remaining > 0:
            chunk = min(remaining, proto.MAX_BURST_WORDS)
            seq   = self._next_seq()
            pkt   = proto.encode_read(addr + offset * 4, chunk, seq=seq)
            try:
                raw   = self._transact(pkt, proto.resp_len(chunk))
                words = proto.decode_read_response(raw, chunk, expected_seq=seq)
            except (XfcpTimeoutError, XfcpProtocolError):
                return None
            results.extend(words)
            offset    += chunk
            remaining -= chunk
        return results

    def write_block(self, addr: int, values: list) -> bool:
        offset = 0
        while offset < len(values):
            chunk = values[offset: offset + proto.MAX_BURST_WORDS]
            seq   = self._next_seq()
            pkt   = proto.encode_write(addr + offset * 4, chunk, seq=seq)
            try:
                raw = self._transact(pkt, proto.resp_len(0, is_write=True), retries=0)
                proto.decode_write_response(raw, expected_seq=seq)
            except (XfcpTimeoutError, XfcpProtocolError):
                return False
            offset += len(chunk)
        return True

    def wait_reg(self, addr: int, mask: int, expected: int,
                 timeout_s: float = 5.0, poll_s: float = 0.1) -> bool:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            val = self.read32(addr)
            if val is not None and (val & mask) == expected:
                return True
            time.sleep(poll_s)
        return False

    def recover(self) -> bool:
        self._transport.drain()
        if not self.ping():
            raise XfcpRecoveryError("Link not recovered after drain")
        return True
