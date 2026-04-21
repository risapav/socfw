from __future__ import annotations
from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.rtl import RtlModule


class QuartusFilesEmitter:
    family = "files"

    def emit(self, ctx: BuildContext, ir: RtlModule) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "files.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("set_global_assignment -name SYSTEMVERILOG_FILE gen/rtl/soc_top.sv")

        for fp in ir.extra_sources:
            if fp.endswith(".qip"):
                lines.append(f"set_global_assignment -name QIP_FILE {fp}")
            elif fp.endswith(".sdc"):
                lines.append(f"set_global_assignment -name SDC_FILE {fp}")
            elif fp.endswith(".v"):
                lines.append(f"set_global_assignment -name VERILOG_FILE {fp}")
            elif fp.endswith(".vhd") or fp.endswith(".vhdl"):
                lines.append(f"set_global_assignment -name VHDL_FILE {fp}")
            else:
                lines.append(f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}")

        out.write_text("\n".join(lines) + "\n", encoding="ascii")
        return [GeneratedArtifact(family=self.family, path=str(out), generator=self.__class__.__name__)]
