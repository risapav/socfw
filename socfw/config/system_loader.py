from __future__ import annotations

from pathlib import Path

from socfw.config.board_loader import BoardLoader
from socfw.config.cpu_loader import CpuLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.project_loader import ProjectLoader
from socfw.config.timing_loader import TimingLoader
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation
from socfw.core.result import Result
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel


class SystemLoader:
    def __init__(self) -> None:
        self.board_loader = BoardLoader()
        self.project_loader = ProjectLoader()
        self.timing_loader = TimingLoader()
        self.ip_loader = IpLoader()
        self.cpu_loader = CpuLoader()

    def load(self, project_file: str) -> Result[SystemModel]:
        diags: list[Diagnostic] = []

        prj_res = self.project_loader.load(project_file)
        diags.extend(prj_res.diagnostics)
        if not prj_res.ok or prj_res.value is None:
            return Result(diagnostics=diags)

        prj_bundle = prj_res.value
        project = prj_bundle["project"]
        cpu = prj_bundle["cpu"]
        ram = prj_bundle["ram"]
        firmware = prj_bundle.get("firmware")
        reset_vector = prj_bundle["reset_vector"]
        stack_percent = prj_bundle["stack_percent"]

        project_dir = Path(project_file).parent

        if not project.board_file:
            return Result(
                diagnostics=diags + [
                    Diagnostic(
                        code="SYS100",
                        severity=Severity.ERROR,
                        message="project.board_file is required",
                        subject="project.board_file",
                        locations=(SourceLocation(file=project_file),),
                    )
                ]
            )

        board_path = str(project_dir / project.board_file)
        board_res = self.board_loader.load(board_path)
        diags.extend(board_res.diagnostics)
        if not board_res.ok or board_res.value is None:
            return Result(diagnostics=diags)
        board = board_res.value

        resolved_ip_dirs = [
            str(project_dir / p) for p in project.registries_ip
        ]
        catalog_res = self.ip_loader.load_catalog(resolved_ip_dirs)
        diags.extend(catalog_res.diagnostics)
        ip_catalog = catalog_res.value or {}

        cpu_catalog_res = self.cpu_loader.load_catalog(resolved_ip_dirs)
        diags.extend(cpu_catalog_res.diagnostics)
        cpu_catalog = cpu_catalog_res.value or {}

        timing = None
        if project.timing_file:
            timing_path = str(project_dir / project.timing_file)
            tim_res = self.timing_loader.load(timing_path)
            diags.extend(tim_res.diagnostics)
            if not tim_res.ok:
                return Result(diagnostics=diags)
            timing = tim_res.value

        system = SystemModel(
            board=board,
            project=project,
            timing=timing,
            ip_catalog=ip_catalog,
            cpu_catalog=cpu_catalog,
            cpu=cpu,
            ram=ram,
            firmware=firmware,
            reset_vector=reset_vector,
            stack_percent=stack_percent,
            sources=SourceContext(
                project_file=project_file,
                board_file=board_path,
                timing_file=str(project_dir / project.timing_file) if project.timing_file else None,
                ip_files={k: "" for k in ip_catalog.keys()},
                cpu_files={k: "" for k in cpu_catalog.keys()},
            ),
        )

        return Result(value=system, diagnostics=diags)
