# core/register.py

class AxilRegister:
    """
    Deskriptor pre AXI-Lite register.
    Umožňuje pristupovať k registrom ako k atribútom objektu.
    """
    def __init__(self, offset, bit_offset=0, bit_width=32, readonly=True, doc=""):
        self.offset = offset
        self.bit_offset = bit_offset
        self.bit_width = bit_width
        self.readonly = readonly
        self.__doc__ = doc
        # Maska pre danú šírku bitov
        self.mask = ((1 << bit_width) - 1) << bit_offset

    def __get__(self, obj, objtype=None):
        if obj is None: return self
        raw_val = obj.read32(self.offset)
        if raw_val is None: return 0
        return (raw_val & self.mask) >> self.bit_offset

    def __set__(self, obj, value):
        if self.readonly:
            raise AttributeError(f"Register na offsete {hex(self.offset)} je len na čítanie (RO).")

        # Ak zapisujeme menej ako 32 bitov, musíme zachovať ostatné bity (Read-Modify-Write)
        current = 0 if self.bit_width == 32 else (obj.read32(self.offset) or 0)
        new_val = (current & ~self.mask) | ((value << self.bit_offset) & self.mask)
        obj.write32(self.offset, new_val)