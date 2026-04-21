from enum import Enum


class PortDir(str, Enum):
    INPUT = "input"
    OUTPUT = "output"
    INOUT = "inout"


class AccessType(str, Enum):
    RO = "ro"
    RW = "rw"
    WO = "wo"


class BusRole(str, Enum):
    MASTER = "master"
    SLAVE = "slave"
    BRIDGE = "bridge"
