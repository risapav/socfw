import tempfile
from pathlib import Path
from unittest.mock import MagicMock

from socfw.emit.sim_filelist_emitter import SimFilelistEmitter
from socfw.model.ip import IpArtifactBundle


def _make_system(synthesis=(), simulation=(), include_dirs=()):
    bundle = IpArtifactBundle(
        synthesis=tuple(synthesis),
        simulation=tuple(simulation),
        include_dirs=tuple(include_dirs),
    )
    ip = MagicMock()
    ip.artifacts = bundle

    mod = MagicMock()
    mod.type_name = "my_ip"

    system = MagicMock()
    system.project.modules = [mod]
    system.ip_catalog.get.return_value = ip
    return system


def _lines(out_dir: str) -> list[str]:
    return (Path(out_dir) / "sim" / "files.f").read_text().splitlines()


def test_absolute_paths_in_filelist():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system(synthesis=["/abs/path/my_ip.sv"])
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        soc_top_line = next(l for l in lines if "soc_top.sv" in l)
        assert soc_top_line.startswith("/"), "soc_top.sv path must be absolute"
        assert Path(soc_top_line).is_absolute()


def test_rtl_dir_added_as_incdir():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system()
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        rtl_incdir = next((l for l in lines if l.startswith("+incdir+")), None)
        assert rtl_incdir is not None
        assert "rtl" in rtl_incdir


def test_synthesis_sv_in_sources():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system(synthesis=["/ip/my_ip.sv"])
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        assert any("/ip/my_ip.sv" in l for l in lines)


def test_synthesis_vh_adds_incdir():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system(synthesis=["/ip/include/defs.vh"])
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        assert any("+incdir+/ip/include" in l for l in lines)
        # Header itself should NOT appear as a source file
        assert not any("defs.vh" in l and not l.startswith("+incdir+") for l in lines)


def test_simulation_sv_adds_lib_dir():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system(simulation=["/vendor/sim/clkpll.v"])
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        assert any("-y /vendor/sim" in l for l in lines)


def test_explicit_include_dirs_propagated():
    with tempfile.TemporaryDirectory() as tmp:
        system = _make_system(include_dirs=["/some/custom/include"])
        SimFilelistEmitter().emit(tmp, system, [])
        lines = _lines(tmp)
        assert any("+incdir+/some/custom/include" in l for l in lines)
