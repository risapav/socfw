# Backward-compat shim — implementation moved to xfcp/ package (navrhy_03 Faza B).
from xfcp.bus import XfcpBus as XFCPBus

__all__ = ['XFCPBus']
