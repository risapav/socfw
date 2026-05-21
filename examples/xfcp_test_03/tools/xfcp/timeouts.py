from dataclasses import dataclass


@dataclass
class XfcpTimeouts:
    response_s: float = 1.0   # serial read timeout per transaction
    recovery_s: float = 0.3   # flush drain time after a failed transaction
    open_s:     float = 1.0   # serial port open timeout
