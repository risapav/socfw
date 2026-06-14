from dataclasses import dataclass


@dataclass
class XfcpTimeouts:
    response_s: float = 1.0   # read timeout per transaction
    recovery_s: float = 0.3   # drain time after a failed transaction
    open_s:     float = 1.0   # serial port open timeout
    udp_s:      float = 2.0   # UDP socket recv timeout
