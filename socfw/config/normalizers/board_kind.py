from __future__ import annotations


def infer_kind(node: dict) -> str | None:
    """Infer the `kind` of a board resource node from its fields."""
    if "kind" in node:
        return node["kind"]

    direction = node.get("direction") or node.get("dir")
    has_pins = "pins" in node
    has_pin = "pin" in node
    has_width = "width" in node
    has_signals = bool(node.get("signals"))
    has_groups = bool(node.get("groups"))

    if has_signals or has_groups:
        return None  # container node, not a leaf

    if direction == "inout":
        if has_pins or has_width:
            return "inout"

    if has_pins or (has_width and not has_pin):
        return "vector"

    if has_pin:
        return "scalar"

    return None


def normalize_resource_kinds(node: dict, *, path: str = "") -> dict:
    """Recursively add inferred `kind` to resource nodes that lack it."""
    if not isinstance(node, dict):
        return node

    result = dict(node)

    if "kind" not in result and ("top_name" in result or "soc_top_name" in result or "pin" in result or "pins" in result):
        inferred = infer_kind(result)
        if inferred is not None:
            result["kind"] = inferred

    for key in ("signals", "groups"):
        if isinstance(result.get(key), dict):
            result[key] = {
                k: normalize_resource_kinds(v, path=f"{path}.{key}.{k}")
                for k, v in result[key].items()
            }

    return result


def normalize_board_resource_kinds(resources: dict) -> dict:
    """Walk the full resources dict and infer kind for all leaf resources."""
    if not isinstance(resources, dict):
        return resources

    result = {}
    for key, val in resources.items():
        if isinstance(val, dict):
            if "kind" not in val and ("top_name" in val or "soc_top_name" in val or "pin" in val or "pins" in val):
                val = normalize_resource_kinds(val, path=key)
            elif isinstance(val, dict):
                val = normalize_board_resource_kinds(val)
        result[key] = val
    return result
