class XfcpError(Exception):
    pass


class XfcpTimeoutError(XfcpError):
    pass


class XfcpProtocolError(XfcpError):
    pass


class XfcpRecoveryError(XfcpError):
    pass


class XfcpStatusError(XfcpError):
    """FPGA returned a non-zero STATUS byte in the response header."""

    STATUS_NAMES = {
        0x00: 'OK',
        0x01: 'BAD_OPCODE',
        0x02: 'BAD_LENGTH',
        0x03: 'BAD_ADDRESS',
        0x04: 'AXI_SLVERR',
        0x05: 'AXI_DECERR',
        0x06: 'TIMEOUT',
        0x07: 'BUSY',
        0x08: 'OVERFLOW',
        0x09: 'UNSUPPORTED',
        0x7F: 'INTERNAL_ERROR',
    }

    def __init__(self, status: int, context: str = ''):
        self.status = status
        name = self.STATUS_NAMES.get(status, f'UNKNOWN_0x{status:02X}')
        msg = f"XFCP status error: {name} (0x{status:02X})"
        if context:
            msg += f" [{context}]"
        super().__init__(msg)
