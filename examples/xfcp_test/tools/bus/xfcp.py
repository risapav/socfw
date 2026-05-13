import serial
import struct

class XFCPBus:
    """
    Nízkoúrovňový driver pre XFCP (Xilinx FPGA Control Protocol) bridge.
    Implementuje optimalizované čítanie blokov dát pre zníženie latencie UART-u.
    """
    def __init__(self, port='/dev/ttyUSB0', baudrate=115200, timeout=0.8):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.ser = None

    def __enter__(self):
        try:
            self.ser = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
            self.ser.reset_input_buffer()
            return self
        except Exception as e:
            raise ConnectionError(f"Nepodarilo sa otvoriť port {self.port}: {e}")

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def read32(self, addr):
        """Prečíta jeden 32-bitový register (4 byty)."""
        return self.read_block(addr, 1)[0] if self.read_block(addr, 1) else None

    def read_block(self, addr, num_words):
        """
        Burst Read: Prečíta N 32-bitových slov začínajúcich na danej adrese.
        Znižuje počet hlavičiek prenášaných cez UART.
        """
        num_bytes = num_words * 4
        # Opcode 0x10 = READ
        # Formát: [0xFF][0x10][Address 4B][Length 2B]
        pkt = b'\xff\x10' + struct.pack(">I", addr) + struct.pack(">H", num_bytes)

        self.ser.write(pkt)

        # Odpoveď: [0xFF][0x11][Data NB]
        expected_len = 2 + num_bytes
        resp = self.ser.read(expected_len)

        if len(resp) == expected_len and resp[:2] == b'\xff\x11':
            # Rozbalíme N malých endian (Intel/AXI) 32-bitových slov
            return list(struct.unpack(f"<{num_words}I", resp[2:]))
        return None

    def write32(self, addr, val):
        """Zapíše 32-bitovú hodnotu na adresu."""
        # Opcode 0x12 = WRITE
        # Formát: [0xFF][0x12][Address 4B][Length 2B][Data 4B]
        pkt = b'\xff\x12' + struct.pack(">I", addr) + struct.pack(">H", 4) + struct.pack("<I", val)
        self.ser.write(pkt)
        resp = self.ser.read(2)
        return resp == b'\xff\x13'