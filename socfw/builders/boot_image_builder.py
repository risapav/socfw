from __future__ import annotations

from pathlib import Path

from socfw.model.image import BootImage
from socfw.model.system import SystemModel


class BootImageBuilder:
    def build(self, system: SystemModel, out_dir: str) -> BootImage | None:
        if system.ram is None:
            return None
        if not system.ram.init_file:
            return None

        input_file = system.ram.init_file
        output_file = str(Path(out_dir) / "sw" / "software.hex")

        return BootImage(
            input_file=input_file,
            output_file=output_file,
            input_format="bin" if input_file.endswith(".bin") else "hex",
            output_format=system.ram.image_format,
            size_bytes=system.ram.size,
            endian="little",
        )
