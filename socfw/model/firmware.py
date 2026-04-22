from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class FirmwareModel:
    enabled: bool = False
    src_dir: str | None = None
    out_dir: str = "build/fw"
    linker_script: str | None = None
    elf_file: str = "firmware.elf"
    bin_file: str = "firmware.bin"
    hex_file: str = "firmware.hex"
    tool_prefix: str = "riscv32-unknown-elf-"
    cflags: list[str] = field(default_factory=list)
    ldflags: list[str] = field(default_factory=list)
