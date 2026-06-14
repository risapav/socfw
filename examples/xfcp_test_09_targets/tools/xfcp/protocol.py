import struct

SOP_REQ  = 0xFE   # request SOP  (PC -> FPGA)
SOP_RESP = 0xFD   # response SOP (FPGA -> PC)

OP_GET_CAPS              = 0x01
OP_RESP_GET_CAPS         = 0x02
OP_GET_TARGET_INFO       = 0x03
OP_RESP_GET_TARGET_INFO  = 0x04
OP_READ              = 0x10
OP_WRITE             = 0x11
OP_RESP_READ         = 0x12
OP_RESP_WRITE        = 0x13
OP_STREAM_WRITE      = 0x20
OP_STREAM_READ       = 0x21
OP_RESP_STREAM_WRITE = 0x22
OP_RESP_STREAM_READ  = 0x23

CAPS_PAYLOAD_LEN   = 8   # 2x32-bit words, MSB-first
TARGET_PAYLOAD_LEN = 16  # 4x32-bit words, MSB-first

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


def encode_get_caps(seq: int = 0) -> bytes:
    """Encode GET_CAPS request (COUNT=0, no address/data payload)."""
    return bytes([SOP_REQ, OP_GET_CAPS, seq & 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])


def resp_len_get_caps() -> int:
    return RESP_HEADER + CAPS_PAYLOAD_LEN + RESP_TRAILER


def encode_get_target_info(index: int, seq: int = 0) -> bytes:
    """Encode GET_TARGET_INFO request (COUNT=0, ADDR[7:0]=index)."""
    return bytes([SOP_REQ, OP_GET_TARGET_INFO, seq & 0xFF,
                  0x00, 0x00,
                  0x00, 0x00, 0x00, index & 0xFF])


def resp_len_get_target_info() -> int:
    return RESP_HEADER + TARGET_PAYLOAD_LEN + RESP_TRAILER


def decode_get_target_info_response(raw: bytes, expected_seq: int = None) -> dict:
    """Decode RESP_GET_TARGET_INFO, return target dict. Raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len_get_target_info()
    if len(raw) != expected:
        raise XfcpProtocolError(f"GET_TARGET_INFO response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_GET_TARGET_INFO:
        raise XfcpProtocolError(f"Bad SOP/OP in GET_TARGET_INFO response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='get_target_info')
    p = raw[RESP_HEADER: RESP_HEADER + TARGET_PAYLOAD_LEN]
    return {
        "target_type":   p[0],         # 0x01=AXIL, 0x02=STREAM
        "target_id":     p[1],
        "flags":         p[2],
        "base_addr":     struct.unpack(">I", p[4:8])[0],
        "max_transfer":  (p[8] << 8) | p[9],
        "align":         p[10],
        "name":          p[12:16].decode("ascii", errors="replace"),
    }


def decode_get_caps_response(raw: bytes, expected_seq: int = None) -> dict:
    """Decode RESP_GET_CAPS, return caps dict. Raise on error or non-OK status."""
    from .errors import XfcpProtocolError, XfcpStatusError
    expected = resp_len_get_caps()
    if len(raw) != expected:
        raise XfcpProtocolError(f"GET_CAPS response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_GET_CAPS:
        raise XfcpProtocolError(f"Bad SOP/OP in GET_CAPS response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(
            f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}"
        )
    if raw[3] != 0x00:
        raise XfcpStatusError(raw[3], context='get_caps')
    p = raw[RESP_HEADER: RESP_HEADER + CAPS_PAYLOAD_LEN]
    return {
        "proto_major":      p[0],
        "proto_minor":      p[1],
        "num_axil_slots":   p[2],
        "num_stream_slots": p[3],
        "max_stream_bytes": (p[4] << 8) | p[5],
        "stream_align":     p[6],
        "caps_flags":       p[7],
    }
