from __future__ import annotations

from pathlib import Path

from socfw.catalog.index import CatalogIndex


class CatalogIndexer:
    def index_packs(self, roots: list[str]) -> CatalogIndex:
        idx = CatalogIndex()

        for root in roots:
            rp = Path(root).expanduser().resolve()
            if not rp.exists():
                continue

            idx.pack_roots.append(str(rp))

            boards = rp / "boards"
            ip = rp / "ip"
            cpu = rp / "cpu"
            vendor = rp / "vendor"
            examples = rp / "examples"

            if boards.exists():
                idx.board_dirs.append(str(boards))
            if ip.exists():
                idx.ip_dirs.append(str(ip))
            if cpu.exists():
                idx.cpu_dirs.append(str(cpu))
            if vendor.exists():
                idx.vendor_dirs.append(str(vendor))
            if examples.exists():
                idx.example_dirs.append(str(examples))

        return idx
