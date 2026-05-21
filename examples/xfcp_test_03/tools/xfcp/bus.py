import time

from .errors import XfcpError, XfcpTimeoutError, XfcpProtocolError, XfcpRecoveryError
from .timeouts import XfcpTimeouts
from .transport import SerialTransport
from . import protocol as proto

_SYSC_ADDR = 0xFF000000   # slot 0 used as ping target


class XfcpBus:
    """XFCP register-access bus over UART."""

    def __init__(
        self,
        port:      str   = '/dev/ttyUSB0',
        baudrate:  int   = 115200,
        timeouts:  XfcpTimeouts = None,
        retries:   int   = 1,
    ):
        self._timeouts = timeouts or XfcpTimeouts()
        self._retries  = retries
        self._transport = SerialTransport(port, baudrate, self._timeouts)

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------

    def __enter__(self):
        self._transport.__enter__()
        return self

    def __exit__(self, *args):
        self._transport.__exit__(*args)

    # ------------------------------------------------------------------
    # Internal transaction engine
    # ------------------------------------------------------------------

    def _transact(self, pkt: bytes, expected: int, retries: int = None) -> bytes:
        """
        Send pkt, read expected bytes.
        Flushes before first attempt to drop stale bytes from prior failures.
        On partial read: drain and retry up to `retries` more times.
        Raises XfcpTimeoutError when all attempts exhausted.
        """
        if retries is None:
            retries = self._retries
        self._transport.flush_rx()
        for attempt in range(retries + 1):
            self._transport.write(pkt)
            resp = self._transport.read(expected)
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
        """Return True if FPGA responds to a single-register read at SYSC slot."""
        try:
            result = self.read32(_SYSC_ADDR)
            return result is not None
        except XfcpError:
            return False

    def read32(self, addr: int) -> int:
        """Read one 32-bit register. Returns int or None on timeout."""
        result = self.read_block(addr, 1)
        return result[0] if result is not None else None

    def write32(self, addr: int, val: int) -> bool:
        """
        Write one 32-bit value to addr.
        Returns True on ACK, False on timeout/protocol error.
        Never retries — re-sending a pulse register would trigger it twice.
        """
        pkt = proto.encode_write(addr, [val])
        try:
            raw = self._transact(pkt, proto.resp_len(0, is_write=True), retries=0)
            proto.decode_write_response(raw)
            return True
        except (XfcpTimeoutError, XfcpProtocolError):
            return False

    def read_block(self, addr: int, num_words: int) -> list:
        """
        Burst read of num_words 32-bit registers starting at addr.
        Auto-chunks at MAX_BURST_WORDS to stay within RTL rfifo limits.
        Returns list of ints or None if any chunk fails.
        """
        results = []
        offset  = 0
        remaining = num_words
        while remaining > 0:
            chunk = min(remaining, proto.MAX_BURST_WORDS)
            pkt   = proto.encode_read(addr + offset * 4, chunk)
            try:
                raw   = self._transact(pkt, proto.resp_len(chunk))
                words = proto.decode_read_response(raw, chunk)
            except (XfcpTimeoutError, XfcpProtocolError):
                return None
            results.extend(words)
            offset    += chunk
            remaining -= chunk
        return results

    def write_block(self, addr: int, values: list) -> bool:
        """
        Burst write of values (list of 32-bit ints) starting at addr.
        Auto-chunks at MAX_BURST_WORDS to stay within RTL rfifo limits.
        Returns True only if all chunks are ACKed.
        Never retries individual chunks — writes may not be idempotent.
        """
        offset = 0
        while offset < len(values):
            chunk  = values[offset: offset + proto.MAX_BURST_WORDS]
            pkt    = proto.encode_write(addr + offset * 4, chunk)
            try:
                raw = self._transact(pkt, proto.resp_len(0, is_write=True), retries=0)
                proto.decode_write_response(raw)
            except (XfcpTimeoutError, XfcpProtocolError):
                return False
            offset += len(chunk)
        return True

    def wait_reg(
        self,
        addr:       int,
        mask:       int,
        expected:   int,
        timeout_s:  float = 5.0,
        poll_s:     float = 0.1,
    ) -> bool:
        """Poll addr until (read32(addr) & mask) == expected, or timeout."""
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            val = self.read32(addr)
            if val is not None and (val & mask) == expected:
                return True
            time.sleep(poll_s)
        return False

    def recover(self) -> bool:
        """
        Drain RX buffer and verify link with a ping.
        Call after unexpected errors to re-sync with FPGA.
        Raises XfcpRecoveryError if ping still fails after drain.
        """
        self._transport.drain()
        if not self.ping():
            raise XfcpRecoveryError("Link not recovered after drain")
        return True
