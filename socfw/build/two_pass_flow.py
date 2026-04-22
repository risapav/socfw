from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from socfw.build.context import BuildContext, BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.model.image import BootImage
from socfw.tools.bin2hex_runner import Bin2HexRunner
from socfw.tools.firmware_builder import FirmwareBuilder
from socfw.tools.testbench_stager import TestbenchStager


class TwoPassBuildFlow:
    def __init__(self, templates_dir: str) -> None:
        self.pipeline = FullBuildPipeline(templates_dir=templates_dir)
        self.firmware_builder = FirmwareBuilder()
        self.bin2hex = Bin2HexRunner()
        self.tb_stager = TestbenchStager()

    def run(self, request: BuildRequest):
        self.tb_stager.stage(request.project_file, request.out_dir)

        # pass 1: generate headers/linker/docs/top without final RAM init
        first = self.pipeline.run(request)
        if not first.ok:
            return first

        # reload system to get fresh mutable model
        loaded = self.pipeline.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            first.diagnostics.extend(loaded.diagnostics)
            first.ok = False
            return first

        system = loaded.value

        if system.firmware is None or not system.firmware.enabled or system.ram is None:
            return first

        fw_res = self.firmware_builder.build(system, request.out_dir)
        first.diagnostics.extend(fw_res.diagnostics)
        if not fw_res.ok or fw_res.value is None:
            first.ok = False
            return first

        fw_boot = BootImage(
            input_file=fw_res.value.bin,
            output_file=fw_res.value.hex,
            input_format="bin",
            output_format="hex",
            size_bytes=system.ram.size,
            endian="little",
        )
        conv = self.bin2hex.run(fw_boot)
        first.diagnostics.extend(conv.diagnostics)
        if not conv.ok or conv.value is None:
            first.ok = False
            return first

        # patch RAM init and rerun full pipeline
        system.ram = replace(system.ram, init_file=conv.value, image_format="hex")

        second = self.pipeline.pipeline.run(request, system)
        second.diagnostics = loaded.diagnostics + second.diagnostics + first.diagnostics

        if not second.ok:
            return second

        out_ctx = BuildContext(out_dir=Path(request.out_dir))
        second.manifest = self.pipeline.emitters.emit_all(
            out_ctx,
            board_ir=second.board_ir,
            timing_ir=second.timing_ir,
            rtl_ir=second.rtl_ir,
            software_ir=second.software_ir,
            docs_ir=second.docs_ir,
            register_block_irs=second.register_block_irs,
            peripheral_shell_irs=second.peripheral_shell_irs,
        )

        report_paths = self.pipeline.reports.emit_all(
            system=system,
            design=second.design,
            result=second,
            out_dir=request.out_dir,
        )
        for p in report_paths:
            second.manifest.add("report", p, "ReportOrchestrator")

        second.manifest.add("firmware", fw_res.value.elf, "FirmwareBuilder")
        second.manifest.add("firmware", fw_res.value.bin, "FirmwareBuilder")
        second.manifest.add("firmware", fw_res.value.hex, "Bin2HexRunner")

        return second
