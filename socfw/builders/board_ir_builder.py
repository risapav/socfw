from __future__ import annotations

from socfw.elaborate.design import ElaboratedDesign
from socfw.ir.board import BoardIR


class BoardIRBuilder:
    def build(self, design: ElaboratedDesign) -> BoardIR:
        board = design.system.board
        ir = BoardIR(
            family=board.fpga_family,
            device=board.fpga_part,
        )

        ir.add_scalar(
            top_name=board.sys_clock.top_name,
            pin=board.sys_clock.pin,
            io_standard=board.sys_clock.io_standard,
        )
        ir.add_scalar(
            top_name=board.sys_reset.top_name,
            pin=board.sys_reset.pin,
            io_standard=board.sys_reset.io_standard,
            weak_pull_up=board.sys_reset.weak_pull_up,
        )

        seen_scalars: set[tuple[str, str]] = set()
        seen_vectors: set[tuple[str, tuple[tuple[int, str], ...]]] = set()

        for binding in design.port_bindings:
            for ext in binding.resolved:
                if ext.pin is not None:
                    key = (ext.top_name, ext.pin)
                    if key in seen_scalars:
                        continue
                    ir.add_scalar(
                        top_name=ext.top_name,
                        pin=ext.pin,
                        io_standard=ext.io_standard,
                        weak_pull_up=ext.weak_pull_up,
                    )
                    seen_scalars.add(key)

                elif ext.pins is not None:
                    norm = tuple(sorted(ext.pins.items()))
                    key_v = (ext.top_name, norm)
                    if key_v in seen_vectors:
                        continue
                    ir.add_vector(
                        top_name=ext.top_name,
                        pins=ext.pins,
                        io_standard=ext.io_standard,
                        weak_pull_up=ext.weak_pull_up,
                    )
                    seen_vectors.add(key_v)

        return ir
