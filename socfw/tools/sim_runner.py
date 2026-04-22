from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result


class SimRunner:
    def run_iverilog(self, out_dir: str, top: str = "tb_soc_top") -> Result[str]:
        if shutil.which("iverilog") is None:
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM001",
                    severity=Severity.WARNING,
                    message="iverilog not found, skipping simulation",
                    subject="simulation",
                )
            ])

        sim_dir = Path(out_dir) / "sim"
        filelist = sim_dir / "files.f"
        vvp_file = sim_dir / "sim.vvp"

        cmd_compile = [
            "iverilog",
            "-g2012",
            "-s", top,
            "-o", str(vvp_file),
            "-f", str(filelist),
        ]

        try:
            subprocess.run(cmd_compile, check=True, cwd=out_dir)
            subprocess.run(["vvp", str(vvp_file)], check=True, cwd=out_dir)
        except subprocess.CalledProcessError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM002",
                    severity=Severity.ERROR,
                    message=f"Simulation failed: {exc}",
                    subject="simulation",
                )
            ])

        return Result(value=str(vvp_file))
