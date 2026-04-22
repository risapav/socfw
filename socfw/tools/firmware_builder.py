from __future__ import annotations

import subprocess
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.image import FirmwareArtifacts


class FirmwareBuilder:
    def build(self, system, out_dir: str) -> Result[FirmwareArtifacts]:
        if system.firmware is None or not system.firmware.enabled:
            return Result()

        fw = system.firmware
        if fw.src_dir is None:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FW001",
                        severity=Severity.ERROR,
                        message="firmware.enabled=true but firmware.src_dir is missing",
                        subject="project.firmware",
                    )
                ]
            )

        outp = Path(out_dir) / "fw"
        outp.mkdir(parents=True, exist_ok=True)

        elf = str(outp / fw.elf_file)
        binf = str(outp / fw.bin_file)
        hexf = str(outp / fw.hex_file)

        cc = f"{fw.tool_prefix}gcc"
        objcopy = f"{fw.tool_prefix}objcopy"

        c_sources = sorted(str(p) for p in Path(fw.src_dir).glob("*.c"))
        asm_sources = sorted(str(p) for p in Path(fw.src_dir).glob("*.S"))
        sources = c_sources + asm_sources
        if not sources:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FW002",
                        severity=Severity.ERROR,
                        message=f"No firmware sources found in firmware.src_dir={fw.src_dir}",
                        subject="project.firmware",
                    )
                ]
            )

        cmd_compile = [
            cc,
            "-Os",
            "-march=rv32im",
            "-mabi=ilp32",
            "-ffreestanding",
            "-nostdlib",
            "-Wl,-Bstatic",
            "-Wl,--strip-debug",
            "-o", elf,
            *sources,
        ]

        if fw.linker_script:
            cmd_compile.extend(["-T", fw.linker_script])

        cmd_compile.extend(fw.cflags)
        cmd_compile.extend(fw.ldflags)

        try:
            subprocess.run(cmd_compile, check=True)
            subprocess.run([objcopy, "-O", "binary", elf, binf], check=True)
        except FileNotFoundError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FW003",
                        severity=Severity.ERROR,
                        message=f"Firmware tool not found: {exc}",
                        subject="project.firmware",
                    )
                ]
            )
        except subprocess.CalledProcessError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="FW004",
                        severity=Severity.ERROR,
                        message=f"Firmware build failed: {exc}",
                        subject="project.firmware",
                    )
                ]
            )

        return Result(value=FirmwareArtifacts(elf=elf, bin=binf, hex=hexf))
