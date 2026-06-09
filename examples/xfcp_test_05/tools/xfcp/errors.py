class XfcpError(Exception):
    pass


class XfcpTimeoutError(XfcpError):
    pass


class XfcpProtocolError(XfcpError):
    pass


class XfcpRecoveryError(XfcpError):
    pass
