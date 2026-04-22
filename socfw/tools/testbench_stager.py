from __future__ import annotations

import shutil
from pathlib import Path


class TestbenchStager:
    def stage(self, project_file: str, out_dir: str) -> None:
        project_path = Path(project_file)
        tb_dir = project_path.parent / "tb"
        if not tb_dir.exists():
            return

        out_tb_dir = Path(out_dir) / "sim"
        out_tb_dir.mkdir(parents=True, exist_ok=True)

        for tb in tb_dir.glob("*.sv"):
            shutil.copy2(tb, out_tb_dir / tb.name)
