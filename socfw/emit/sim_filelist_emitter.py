from __future__ import annotations

from pathlib import Path

from socfw.model.ip_graph import collect_include_dirs, collect_simulation_files, collect_synthesis_files

_HDR_EXTS = {".vh", ".svh"}
_SRC_EXTS = {".sv", ".v"}


class SimFilelistEmitter:
    def emit(self, out_dir: str, system, planned_bridges: list) -> str:
        out_path = Path(out_dir).resolve()
        sim_dir = out_path / "sim"
        sim_dir.mkdir(parents=True, exist_ok=True)
        out = sim_dir / "files.f"

        src_files: list[str] = []
        include_dirs: set[str] = set()
        lib_dirs: set[str] = set()

        # RTL output dir is always an include path (soc_top.sv lives there)
        include_dirs.add(str(out_path / "rtl"))

        catalog = system.ip_catalog
        used_types = {m.type_name for m in system.project.modules}
        for type_name in sorted(used_types):
            ip = catalog.get(type_name)
            if ip is None:
                continue

            for d in collect_include_dirs(ip, catalog):
                include_dirs.add(d)

            for fp in collect_synthesis_files(ip, catalog):
                p = Path(fp)
                if p.suffix in _SRC_EXTS:
                    src_files.append(fp)
                elif p.suffix in _HDR_EXTS:
                    include_dirs.add(str(p.parent))

            for fp in collect_simulation_files(ip, catalog):
                p = Path(fp)
                if p.suffix in _SRC_EXTS:
                    src_files.append(fp)
                    # Parent dir of simulation-only vendor models → -y library dir
                    lib_dirs.add(str(p.parent))
                elif p.suffix in _HDR_EXTS:
                    include_dirs.add(str(p.parent))

        for bridge in planned_bridges:
            if Path(str(bridge.rtl_file)).suffix in _SRC_EXTS:
                src_files.append(str(bridge.rtl_file))

        lines: list[str] = []

        for d in sorted(include_dirs):
            lines.append(f"+incdir+{d}")

        for d in sorted(lib_dirs):
            lines.append(f"-y {d}")

        lines.append(str(out_path / "rtl" / "soc_top.sv"))
        for fp in sorted(dict.fromkeys(src_files)):
            lines.append(fp)

        tb = sim_dir / "tb_soc_top.sv"
        if tb.exists():
            lines.append(str(tb))

        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return str(out)
