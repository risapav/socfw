"""Resource tree traversal helpers for board resources."""
from __future__ import annotations


def is_resource_leaf(node) -> bool:
    """Return True if node is a terminal board resource (has kind)."""
    if isinstance(node, dict):
        return "kind" in node
    from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardConnectorRole
    return isinstance(node, (BoardScalarSignal, BoardVectorSignal, BoardConnectorRole))


def iter_resource_leaves(resources_or_board, path: str):
    """
    Yield (full_path, resource) for all leaf resources reachable from path.

    Accepts either a raw resources dict or a BoardModel.
    Path is dot-notation without 'board:' prefix.
    """
    if hasattr(resources_or_board, "resources"):
        cur = resources_or_board.resources
    else:
        cur = resources_or_board

    parts = path.split(".")
    for part in parts:
        if not isinstance(cur, dict) or part not in cur:
            return
        cur = cur[part]

    yield from _iter_leaves(cur, path)


def _iter_leaves(node, path: str):
    if is_resource_leaf(node):
        yield path, node
        return
    if isinstance(node, dict):
        for key, val in node.items():
            yield from _iter_leaves(val, f"{path}.{key}")


def collect_resource_pins(node) -> set[str]:
    """Collect all physical pin identifiers from a resource node."""
    pins: set[str] = set()

    if isinstance(node, dict):
        kind = node.get("kind")
        if kind == "scalar":
            pin = node.get("pin")
            if pin:
                pins.add(str(pin))
        elif kind in ("vector", "inout"):
            pin_list = node.get("pins") or []
            if isinstance(pin_list, dict):
                pin_list = list(pin_list.values())
            for p in pin_list:
                if p:
                    pins.add(str(p))
        elif kind == "bundle":
            for sig in (node.get("signals") or {}).values():
                if isinstance(sig, dict):
                    pins.update(collect_resource_pins(sig))
        else:
            pin = node.get("pin")
            if pin:
                pins.add(str(pin))
            for p in (node.get("pins") or []):
                if p:
                    pins.add(str(p))
    else:
        from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardResource, BoardConnectorRole
        if isinstance(node, BoardScalarSignal):
            if node.pin:
                pins.add(node.pin)
        elif isinstance(node, (BoardVectorSignal, BoardConnectorRole)):
            pin_vals = node.pins.values() if isinstance(node.pins, dict) else node.pins
            pins.update(pin_vals)
        elif isinstance(node, BoardResource):
            for sig in node.scalars.values():
                pins.update(collect_resource_pins(sig))
            for vec in node.vectors.values():
                pins.update(collect_resource_pins(vec))

    return pins


def resource_width(node) -> int | None:
    """Return the width of a resource node, or None if unknown."""
    if isinstance(node, dict):
        kind = node.get("kind", "scalar")
        if kind == "scalar":
            return 1
        return int(node.get("width", 1)) if "width" in node else None
    from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardConnectorRole
    if isinstance(node, BoardScalarSignal):
        return 1
    if isinstance(node, (BoardVectorSignal, BoardConnectorRole)):
        return node.width
    return None


def resource_direction(node) -> str | None:
    """Return the direction of a resource node."""
    if isinstance(node, dict):
        return node.get("direction")
    from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardConnectorRole
    if isinstance(node, (BoardScalarSignal, BoardVectorSignal, BoardConnectorRole)):
        return node.direction.value if hasattr(node.direction, "value") else str(node.direction)
    return None
