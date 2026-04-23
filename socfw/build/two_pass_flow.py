from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from socfw.build.cache_store import CacheStore
from socfw.build.cache_version import SOCFW_CACHE_VERSION
from socfw.build.context import BuildContext, BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.build.stage_cache import StageCache
from socfw.model.image import BootImage, FirmwareArtifacts
from socfw.tools.bin2hex_runner import Bin2HexRunner
from socfw.tools.firmware_builder import FirmwareBuilder
from socfw.tools.testbench_stager import TestbenchStager

_FW_STAGE = "firmware_build"


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

        cache = StageCache(CacheStore(request.out_dir))
        fw_fp = self.firmware_builder.fingerprint(system, request.out_dir)
        fw_out_dir = Path(request.out_dir) / "fw"
        fw_outputs = [
            str(fw_out_dir / system.firmware.elf_file),
            str(fw_out_dir / system.firmware.bin_file),
            str(fw_out_dir / system.firmware.hex_file),
        ]

        if fw_fp and cache.check(_FW_STAGE, fw_fp) and all(Path(p).exists() for p in fw_outputs):
            fw_artifacts = FirmwareArtifacts(
                elf=fw_outputs[0],
                bin=fw_outputs[1],
                hex=fw_outputs[2],
            )
            cache.update(_FW_STAGE, fw_fp, outputs=fw_outputs, hit=True, note="cache hit")
        else:
            fw_res = self.firmware_builder.build(system, request.out_dir)
            first.diagnostics.extend(fw_res.diagnostics)
            if not fw_res.ok or fw_res.value is None:
                first.ok = False
                return first
            fw_artifacts = fw_res.value
            if fw_fp:
                cache.update(_FW_STAGE, fw_fp, outputs=[fw_artifacts.elf, fw_artifacts.bin, fw_artifacts.hex], note="rebuilt")

        fw_boot = BootImage(
            input_file=fw_artifacts.bin,
            output_file=fw_artifacts.hex,
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

        second.manifest.add("firmware", fw_artifacts.elf, "FirmwareBuilder")
        second.manifest.add("firmware", fw_artifacts.bin, "FirmwareBuilder")
        second.manifest.add("firmware", fw_artifacts.hex, "Bin2HexRunner")

        return second
