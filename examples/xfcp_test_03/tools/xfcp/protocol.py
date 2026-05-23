import struct

SOP_REQ  = 0xFE   # request SOP  (PC → FPGA)
SOP_RESP = 0xFD   # response SOP (FPGA → PC); differs so TX→RX coupling is S_DROP on FPGA

OP_READ       = 0x10
OP_WRITE      = 0x11
OP_RESP_READ  = 0x12
OP_RESP_WRITE = 0x13

# Response layout: SOP(1) + TYPE(1) + SEQ(1) + DEV_TYPE(2) + DEV_STR(16)
RESP_HEADER  = 21
RESP_TRAILER = 1    # terminating 0x00

# RTL rfifo in xfcp_axi_engine has DEPTH=32 words; bursts above this stall the pipeline.
MAX_BURST_WORDS = 32


def resp_len(num_words: int, is_write: bool = False) -> int:
    if is_write:
        return RESP_HEADER + RESP_TRAILER
    return RESP_HEADER + num_words * 4 + RESP_TRAILER


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


def decode_read_response(raw: bytes, num_words: int, expected_seq: int = None) -> list:
    """Return list of ints extracted from a raw READ response, or raise XfcpProtocolError."""
    from .errors import XfcpProtocolError
    expected = resp_len(num_words)
    if len(raw) != expected:
        raise XfcpProtocolError(f"Read response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_READ:
        raise XfcpProtocolError(f"Bad SOP/OP in read response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}")
    payload = raw[RESP_HEADER: RESP_HEADER + num_words * 4]
    return list(struct.unpack(f">{num_words}I", payload))


def decode_write_response(raw: bytes, expected_seq: int = None) -> None:
    """Validate a raw WRITE response, or raise XfcpProtocolError."""
    from .errors import XfcpProtocolError
    expected = resp_len(0, is_write=True)
    if len(raw) != expected:
        raise XfcpProtocolError(f"Write response length {len(raw)} != {expected}")
    if raw[0] != SOP_RESP or raw[1] != OP_RESP_WRITE:
        raise XfcpProtocolError(f"Bad SOP/OP in write response: {raw[:2].hex()}")
    if expected_seq is not None and raw[2] != (expected_seq & 0xFF):
        raise XfcpProtocolError(f"SEQ mismatch: got 0x{raw[2]:02X}, expected 0x{expected_seq & 0xFF:02X}")
