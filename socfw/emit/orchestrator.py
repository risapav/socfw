from __future__ import annotations

from socfw.build.context import BuildContext
from socfw.build.manifest import BuildManifest
from socfw.plugins.registry import PluginRegistry


class EmitOrchestrator:
    def __init__(self, registry: PluginRegistry) -> None:
        self.registry = registry

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
        peripheral_shell_irs=None,
    ) -> BuildManifest:
        manifest = BuildManifest()

        ordered = [
            ("board", board_ir),
            ("rtl", rtl_ir),
            ("timing", timing_ir),
            ("files", rtl_ir),
            ("software", software_ir),
            ("docs", docs_ir),
        ]

        for family, ir in ordered:
            if ir is None:
                continue
            emitter = self.registry.emitters.get(family)
            if emitter is None:
                continue
            for art in emitter.emit(ctx, ir):
                manifest.artifacts.append(art)

        if register_block_irs:
            emitter = self.registry.emitters.get("rtl_regs")
            if emitter is not None:
                for art in emitter.emit_many(ctx, register_block_irs):
                    manifest.artifacts.append(art)

        if peripheral_shell_irs:
            emitter = self.registry.emitters.get("rtl_shells")
            if emitter is not None:
                for art in emitter.emit_many(ctx, peripheral_shell_irs):
                    manifest.artifacts.append(art)

        return manifest
