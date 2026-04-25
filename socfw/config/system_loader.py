from __future__ import annotations

from pathlib import Path

from socfw.catalog.board_resolver import BoardResolver
from socfw.catalog.indexer import CatalogIndexer
from socfw.config.board_loader import BoardLoader
from socfw.config.cpu_loader import CpuLoader
from socfw.config.ip_loader import IpLoader
from socfw.config.path_checks import check_existing_dir, check_existing_file, resolve_relative
from socfw.config.project_loader import ProjectLoader
from socfw.config.timing_loader import TimingLoader
from socfw.core.diag_builders import err
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel

_BUILTIN_PACK_ROOT = str(Path(__file__).resolve().parents[2] / "packs" / "builtin")


class SystemLoader:
    def __init__(self) -> None:
        self.board_loader = BoardLoader()
        self.project_loader = ProjectLoader()
        self.timing_loader = TimingLoader()
        self.ip_loader = IpLoader()
        self.cpu_loader = CpuLoader()
        self.catalog_indexer = CatalogIndexer()
        self.board_resolver = BoardResolver()

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

        pack_roots = list(project.registries_packs) + [_BUILTIN_PACK_ROOT]
        checked_pack_roots = []
        for p in list(project.registries_packs):
            resolved, p_diags = check_existing_dir(
                code="PATH_PACK001",
                owner_file=project_file,
                ref_path=p,
                subject="registries.packs",
                hint="Check the path under `registries.packs`.",
                severity=Severity.WARNING,
            )
            diags.extend(p_diags)
            if not p_diags:
                checked_pack_roots.append(resolved)
        checked_pack_roots.append(_BUILTIN_PACK_ROOT)
        pack_index = self.catalog_indexer.index_packs(checked_pack_roots)

        if project.board_file:
            resolved_board_path, b_diags = check_existing_file(
                code="PATH_BOARD001",
                owner_file=project_file,
                ref_path=project.board_file,
                subject="project.board_file",
                hint="Check `project.board_file` or remove it to resolve board from packs.",
            )
            diags.extend(b_diags)
            if b_diags:
                return Result(diagnostics=diags)
            explicit_board_file = resolved_board_path
        else:
            explicit_board_file = None
        resolved_board_file = self.board_resolver.resolve(
            board_key=project.board_ref,
            explicit_board_file=explicit_board_file,
            board_dirs=pack_index.board_dirs,
        )

        if resolved_board_file is None:
            return Result(diagnostics=diags + [
                err(
                    "SYS101",
                    f"Unable to resolve board '{project.board_ref}'",
                    "project.board",
                    file=project_file,
                    path="project.board",
                    category="catalog",
                    hints=[
                        "Set project.board_file explicitly.",
                        "Or add a pack containing boards/<board>/board.yaml.",
                    ],
                )
            ])

        board_path = resolved_board_file
        board_res = self.board_loader.load(board_path)
        diags.extend(board_res.diagnostics)
        if not board_res.ok or board_res.value is None:
            return Result(diagnostics=diags)
        board = board_res.value

        # Resolve feature profile into feature_refs
        if project.feature_profile:
            from socfw.board.profile_resolver import ProfileResolver
            resolver = ProfileResolver(board.profiles)
            project.feature_refs = resolver.expand_features(
                project.feature_profile, project.feature_refs
            )

        # Resolve @alias refs in feature_refs and port bindings
        if board.aliases:
            import dataclasses
            from socfw.board.alias_resolver import AliasResolver
            alias_res = AliasResolver(board.aliases, file=project_file)
            project.feature_refs, alias_diags = alias_res.resolve_refs(project.feature_refs)
            diags.extend(alias_diags)
            for mod in project.modules:
                new_bindings = []
                changed = False
                for pb in mod.port_bindings:
                    resolved_target, pb_alias_diags = alias_res.resolve_ref(pb.target)
                    diags.extend(pb_alias_diags)
                    if resolved_target != pb.target:
                        pb = dataclasses.replace(pb, target=resolved_target)
                        changed = True
                    new_bindings.append(pb)
                if changed:
                    mod.port_bindings = new_bindings

        checked_ip_dirs = []
        for p in project.registries_ip:
            resolved, p_diags = check_existing_dir(
                code="PATH_IP001",
                owner_file=project_file,
                ref_path=p,
                subject="registries.ip",
                hint="Check the path under `registries.ip`.",
            )
            diags.extend(p_diags)
            if not p_diags:
                checked_ip_dirs.append(resolved)
        if any(d.severity == Severity.ERROR for d in diags):
            return Result(diagnostics=diags)
        ip_search_dirs = checked_ip_dirs + list(pack_index.ip_dirs)
        catalog_res = self.ip_loader.load_catalog(ip_search_dirs)
        diags.extend(catalog_res.diagnostics)
        ip_catalog = catalog_res.value or {}

        checked_cpu_dirs = []
        for p in project.registries_cpu:
            resolved, p_diags = check_existing_dir(
                code="PATH_CPU001",
                owner_file=project_file,
                ref_path=p,
                subject="registries.cpu",
                hint="Check the path under `registries.cpu`.",
            )
            diags.extend(p_diags)
            if not p_diags:
                checked_cpu_dirs.append(resolved)
        cpu_search_dirs = (
            checked_cpu_dirs
            + checked_ip_dirs
            + list(pack_index.cpu_dirs)
        )
        cpu_catalog_res = self.cpu_loader.load_catalog(cpu_search_dirs)
        diags.extend(cpu_catalog_res.diagnostics)
        cpu_catalog = cpu_catalog_res.value or {}

        timing = None
        if project.timing_file:
            timing_path, t_diags = check_existing_file(
                code="PATH_TIMING001",
                owner_file=project_file,
                ref_path=project.timing_file,
                subject="project.timing.file",
                hint="Check `timing.file` in project.yaml or create the referenced timing YAML.",
            )
            diags.extend(t_diags)
            if t_diags:
                return Result(diagnostics=diags)
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
                ip_files={k: getattr(v, "source_file", "") or "" for k, v in ip_catalog.items()},
                cpu_files={k: getattr(v, "source_file", "") or "" for k, v in cpu_catalog.items()},
                pack_roots=checked_pack_roots,
                ip_search_dirs=ip_search_dirs,
                cpu_search_dirs=cpu_search_dirs,
                aliases_used=[
                    d.message for d in diags
                    if "ALIAS" in str(getattr(d, "code", ""))
                ],
            ),
        )

        return Result(value=system, diagnostics=diags)
