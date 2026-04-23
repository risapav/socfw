from __future__ import annotations

from pathlib import Path

from socfw.build.context import BuildContext
from socfw.build.manifest import GeneratedArtifact
from socfw.ir.files import FilesIR
from socfw.ir.rtl import RtlModuleIR


class QuartusFilesEmitter:
    family = "files"

    def emit(self, ctx: BuildContext, ir: RtlModuleIR | FilesIR) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "files.tcl"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("# AUTO-GENERATED - DO NOT EDIT")
        lines.append("set_global_assignment -name SYSTEMVERILOG_FILE rtl/soc_top.sv")

        if isinstance(ir, FilesIR):
            for q in ir.qip_files:
                lines.append(f"set_global_assignment -name QIP_FILE {q}")
            for fp in ir.rtl_files:
                lines.append(self._file_assignment(fp))
            for s in ir.sdc_files:
                lines.append(f"set_global_assignment -name SDC_FILE {s}")
        else:
            for fp in sorted(ir.extra_sources):
                lines.append(self._file_assignment(fp))

        out.write_text("\n".join(lines) + "\n", encoding="ascii")

        return [
            GeneratedArtifact(
                family=self.family,
                path=str(out),
                generator=self.__class__.__name__,
            )
        ]

    @staticmethod
    def _file_assignment(fp: str) -> str:
        if fp.endswith(".qip"):
            return f"set_global_assignment -name QIP_FILE {fp}"
        if fp.endswith(".sdc"):
            return f"set_global_assignment -name SDC_FILE {fp}"
        if fp.endswith(".v"):
            return f"set_global_assignment -name VERILOG_FILE {fp}"
        if fp.endswith(".vhd") or fp.endswith(".vhdl"):
            return f"set_global_assignment -name VHDL_FILE {fp}"
        return f"set_global_assignment -name SYSTEMVERILOG_FILE {fp}"
