from socfw.schema_docs import available_schemas, get_schema_doc


def test_schema_docs_include_project_and_timing():
    names = available_schemas()
    assert "project" in names
    assert "timing" in names


def test_project_schema_doc_mentions_timing_file():
    text = get_schema_doc("project")
    assert text is not None
    assert "timing:" in text
    assert "file: timing_config.yaml" in text


def test_unknown_schema_returns_none():
    assert get_schema_doc("missing") is None


def test_all_four_schemas_present():
    names = available_schemas()
    assert set(names) >= {"project", "timing", "ip", "board"}


def test_ip_schema_doc_mentions_artifacts():
    text = get_schema_doc("ip")
    assert text is not None
    assert "artifacts:" in text


def test_board_schema_doc_mentions_system_clock():
    text = get_schema_doc("board")
    assert text is not None
    assert "system:" in text
    assert "clock:" in text
