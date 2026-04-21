from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.docs_emitter import DocsEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.register_block_emitter import RegisterBlockEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.software_emitter import SoftwareEmitter
from socfw.emit.timing_emitter import TimingEmitter


class EmitterSuite:
    def __init__(self, templates_dir: str) -> None:
        self.rtl = RtlEmitter(templates_dir)
        self.timing = TimingEmitter(templates_dir)
        self.board = QuartusBoardEmitter()
        self.files = QuartusFilesEmitter()
        self.software = SoftwareEmitter(templates_dir)
        self.docs = DocsEmitter(templates_dir)
        self.regblocks = RegisterBlockEmitter(templates_dir)

    def emit_all(
        self,
        ctx: BuildContext,
        *,
        board_ir,
        timing_ir,
        rtl_ir,
        software_ir=None,
        docs_ir=None,
        register_block_irs=None,
    ) -> BuildManifest:
        manifest = BuildManifest()

        for art in self.board.emit(ctx, board_ir):
            manifest.artifacts.append(art)

        for art in self.rtl.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        for art in self.timing.emit(ctx, timing_ir):
            manifest.artifacts.append(art)

        for art in self.files.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        if software_ir is not None:
            for art in self.software.emit(ctx, software_ir):
                manifest.artifacts.append(art)

        if docs_ir is not None:
            for art in self.docs.emit(ctx, docs_ir):
                manifest.artifacts.append(art)

        if register_block_irs:
            for art in self.regblocks.emit_many(ctx, register_block_irs):
                manifest.artifacts.append(art)

        return manifest
