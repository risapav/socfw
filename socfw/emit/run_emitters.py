from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.emit.board_quartus_emitter import QuartusBoardEmitter
from socfw.emit.files_tcl_emitter import QuartusFilesEmitter
from socfw.emit.rtl_emitter import RtlEmitter
from socfw.emit.timing_emitter import TimingEmitter


class EmitterSuite:
    def __init__(self, templates_dir: str) -> None:
        self.rtl = RtlEmitter(templates_dir)
        self.timing = TimingEmitter(templates_dir)
        self.board = QuartusBoardEmitter()
        self.files = QuartusFilesEmitter()

    def emit_all(self, ctx: BuildContext, *, board_ir, timing_ir, rtl_ir) -> BuildManifest:
        manifest = BuildManifest()

        for art in self.board.emit(ctx, board_ir):
            manifest.artifacts.append(art)

        for art in self.rtl.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        for art in self.timing.emit(ctx, timing_ir):
            manifest.artifacts.append(art)

        for art in self.files.emit(ctx, rtl_ir):
            manifest.artifacts.append(art)

        return manifest
