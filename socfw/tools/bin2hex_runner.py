from __future__ import annotations

import subprocess
import sys

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.image import BootImage


class Bin2HexRunner:
    def __init__(self, tool_path: str = "bin2hex.py") -> None:
        self.tool_path = tool_path

    def run(self, image: BootImage) -> Result[str]:
        if image.input_format != "bin" or image.output_format != "hex":
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IMG001",
                        severity=Severity.ERROR,
                        message=(
                            f"Unsupported image conversion: {image.input_format} -> {image.output_format}"
                        ),
                        subject="boot_image",
                    )
                ]
            )

        cmd = [
            sys.executable,
            self.tool_path,
            image.input_file,
            image.output_file,
            hex(image.size_bytes),
        ]
        if image.endian == "big":
            cmd.append("--big")

        try:
            subprocess.run(cmd, check=True)
        except subprocess.CalledProcessError as exc:
            return Result(
                diagnostics=[
                    Diagnostic(
                        code="IMG002",
                        severity=Severity.ERROR,
                        message=f"bin2hex failed: {exc}",
                        subject="boot_image",
                    )
                ]
            )

        return Result(value=image.output_file)
