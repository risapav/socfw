from socfw import __version__
from socfw.emit.renderer import Renderer


def test_version_exists():
    assert isinstance(__version__, str)
    assert __version__


def test_renderer_constructs(tmp_path):
    tpl_dir = tmp_path / "templates"
    tpl_dir.mkdir()
    (tpl_dir / "hello.j2").write_text("Hello {{ name }}!", encoding="utf-8")

    r = Renderer(str(tpl_dir))
    out = r.render("hello.j2", name="socfw")
    assert out == "Hello socfw!"
