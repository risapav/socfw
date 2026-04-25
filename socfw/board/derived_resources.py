from __future__ import annotations

import copy


PMOD_PIN_ORDER = [1, 2, 3, 4, 7, 8, 9, 10]

ROLE_DEFS: dict[str, dict] = {
    "gpio8": {
        "kind": "inout",
        "direction": "inout",
        "width": 8,
    },
    "led8": {
        "kind": "vector",
        "direction": "output",
        "width": 8,
    },
    "button8": {
        "kind": "vector",
        "direction": "input",
        "width": 8,
    },
    "gpio14": {
        "kind": "inout",
        "direction": "inout",
        "width": 14,
    },
    "gpio2": {
        "kind": "inout",
        "direction": "inout",
        "width": 2,
    },
}


def _resolve_path(node: dict, dotted: str) -> dict | None:
    cur = node
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _insert_path(node: dict, dotted: str, value) -> None:
    parts = dotted.split(".")
    cur = node
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def derive_resources(board_data: dict) -> dict:
    """Expand derived_resources specs into board_data['resources'] and return a deep copy."""
    specs = board_data.get("derived_resources")
    if not specs:
        return board_data

    data = copy.deepcopy(board_data)
    resources = data.setdefault("resources", {})

    for spec in specs:
        name = spec.get("name")
        source = spec.get("from")
        role = spec.get("role")
        top_name = spec.get("top_name")

        if not (name and source and role and top_name):
            continue

        role_def = ROLE_DEFS.get(role)
        if role_def is None:
            continue

        connector = _resolve_path(resources, source)
        if connector is None:
            continue

        pins_map = connector.get("pins") or {}
        if isinstance(pins_map, list):
            pins_map = {i + 1: p for i, p in enumerate(pins_map)}

        # For PMOD connectors, order by canonical PMOD_PIN_ORDER
        source_parts = source.split(".")
        if len(source_parts) >= 2 and source_parts[-2] == "pmod":
            pins = [pins_map[i] for i in PMOD_PIN_ORDER if i in pins_map]
        else:
            pins = [pins_map[k] for k in sorted(pins_map.keys())]

        # Trim to role width
        width = role_def["width"]
        pins = pins[:width]

        resource = {
            **role_def,
            "top_name": top_name,
            "io_standard": spec.get("io_standard") or connector.get("io_standard"),
            "pins": pins,
        }

        _insert_path(resources, name, resource)

    return data
