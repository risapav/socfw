import struct

SOP_REQ  = 0xFE   # request SOP  (PC -> FPGA)
SOP_RESP = 0xFD   # response SOP (FPGA -> PC)

OP_READ              = 0x10
OP_WRITE             = 0x11
OP_RESP_READ         = 0x12
OP_RESP_WRITE        = 0x13
OP_STREAM_WRITE      = 0x20
OP_STREAM_READ       = 0x21
OP_RESP_STREAM_WRITE = 0x22
OP_RESP_STREAM_READ  = 0x23

# Response layout v0.9+STATUS: SOP(1) + TYPE(1) + SEQ(1) + STATUS(1)
RESP_HEADER  = 4
RESP_TRAILER = 1    # terminating 0x00

# RTL rfifo in xfcp_axi_engine has DEPTH=32 words
MAX_BURST_WORDS = 32

# RTL xfcp_axis_adapter MAX_STREAM_BYTES parameter
MAX_STREAM_BYTES = 256


def resp_len(num_words: int, is_write: bool = False) -> int:
    if is_write:
        return RESP_HEADER + RESP_TRAILER
    return RESP_HEADER + num_words * 4 + RESP_TRAILER


def resp_len_stream_write() -> int:
    return RESP_HEADER + RESP_TRAILER


def resp_len_stream_read(count: int) -> int:
    """Response length for STREAM_READ: header + count bytes of data + trailer."""
    return RESP_HEADER + count + RESP_TRAILER


def encode_read(addr: int, num_words: int, seq: int = 0) -> bytes:
    return (
        bytes([SOP_REQ, OP_READ, seq & 0xFF])
        + struct.pack(">H", num_words * 4)
        + struct.pack(">I", addr)
    )


def encode_write(addr: int, values: list, seq: int = 0) -> bytes:
    payload = struct.pack(f">{len(values)}I", *values)
    return (
        bytes([SOP_REQ, OP_WRITE, seq & 0xFF])
        + struct.pack(">H", len(values) * 4)
        + struct.pack(">I", addr)
        + payload
    )


def encode_stream_write(data: bytes, stream_id: int = 0, seq: int = 0) -> bytes:
    """Encode STREAM_WRITE request. data must be a multiple of 4 bytes."""
    return (
        bytes([SOP_REQ, OP_STREAM_WRITE, seq & 0xFF])
        + struct.pack(">H", len(data))
        + struct.pack(">I", stream_id & 0xFF)
        + bytes(data)
    )


def encode_stream_read(count: int, stream_id: int = 0, seq: int = 0) -> bytes:
    """Encode STREAM_READ request. count is number of bytes to read (multiple of 4)."""
    return (
        bytes([SOP_REQ, OP_STREAM_READ, seq & 0xFF])
        + struct.pack(">H", count)
        + struct.pack(">I", stream_id & 0xFF)
    )


def decode_read_response(raw: bytes, num_words: int, expected_seq: int = None) -> list:
    """Return list of ints from a raw READ response, raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len(num_words)
    if len(raw) != expected:
        raise XfcpProtocolError(f"Read response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_READ:
        raise XfcpProtocolError(f"Bad SOP/OP in read response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='read')
    payload = raw[RESP_HEADER: RESP_HEADER + num_words * 4]
    return list(struct.unpack(f">{num_words}I", payload))


def decode_write_response(raw: bytes, expected_seq: int = None) -> None:
    """Validate a raw WRITE response, raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len(0, is_write=True)
    if len(raw) != expected:
        raise XfcpProtocolError(f"Write response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_WRITE:
        raise XfcpProtocolError(f"Bad SOP/OP in write response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='write')


def decode_stream_write_response(raw: bytes, expected_seq: int = None) -> None:
    """Validate a raw STREAM_WRITE response, raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len_stream_write()
    if len(raw) != expected:
        raise XfcpProtocolError(f"Stream write response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_STREAM_WRITE:
        raise XfcpProtocolError(f"Bad SOP/OP in stream write response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='stream_write')


def decode_stream_read_response(raw: bytes, count: int,
                                expected_seq: int = None) -> bytes:
    """Return payload bytes from a STREAM_READ response, raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len_stream_read(count)
    if len(raw) != expected:
        raise XfcpProtocolError(f"Stream read response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_STREAM_READ:
        raise XfcpProtocolError(f"Bad SOP/OP in stream read response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='stream_read')
    return bytes(raw[RESP_HEADER: RESP_HEADER + count])
