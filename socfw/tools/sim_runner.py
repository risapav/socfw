from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result


class SimRunner:
    def run_iverilog(self, out_dir: str, top: str = "tb_soc_top", waveform: bool = True) -> Result[str]:
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
            r = subprocess.run(
                cmd_compile, check=True, cwd=out_dir,
                capture_output=True, text=True,
            )
        except subprocess.CalledProcessError as exc:
            msg = exc.stderr.strip() if exc.stderr else str(exc)
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM002",
                    severity=Severity.ERROR,
                    message=f"iverilog compile failed:\n{msg}",
                    subject="simulation",
                )
            ])

        vvp_cmd = ["vvp"]
        if waveform:
            vvp_cmd += ["-n"]
        vvp_cmd.append(str(vvp_file))

        try:
            r = subprocess.run(
                vvp_cmd, check=True, cwd=out_dir,
                capture_output=True, text=True,
            )
            if r.stdout:
                print(r.stdout, end="")
        except subprocess.CalledProcessError as exc:
            msg = exc.stdout.strip() if exc.stdout else str(exc)
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM003",
                    severity=Severity.ERROR,
                    message=f"simulation failed:\n{msg}",
                    subject="simulation",
                )
            ])

        return Result(value=str(vvp_file))
