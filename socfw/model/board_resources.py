from __future__ import annotations


def _is_leaf_resource(node) -> bool:
    """Return True if node is a terminal board resource (has kind)."""
    if isinstance(node, dict):
        return "kind" in node
    from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardConnectorRole
    return isinstance(node, (BoardScalarSignal, BoardVectorSignal, BoardConnectorRole))


def iter_resource_leaves(board, path: str):
    """
    Yield (full_path, resource) for all leaf resources reachable from path.

    Path is dot-notation without 'board:' prefix, e.g. 'external.sdram'.
    If the path resolves directly to a leaf resource, yields just that.
    If it resolves to a dict/group, yields all leaves recursively.
    """
    cur = board.resources
    parts = path.split(".")
    for part in parts:
        if not isinstance(cur, dict) or part not in cur:
            return
        cur = cur[part]

    yield from _iter_leaves(cur, path)


def _iter_leaves(node, path: str):
    if _is_leaf_resource(node):
        yield path, node
        return
    if isinstance(node, dict):
        for key, val in node.items():
            yield from _iter_leaves(val, f"{path}.{key}")


def collect_pins(resource) -> set[str]:
    """Collect all physical pin identifiers from a resource (dict or model object)."""
    pins: set[str] = set()

    if isinstance(resource, dict):
        kind = resource.get("kind")
        if kind == "scalar":
            pin = resource.get("pin")
            if pin:
                pins.add(str(pin))
        elif kind in ("vector", "inout"):
            for p in (resource.get("pins") or []):
                if p:
                    pins.add(str(p))
        elif kind == "bundle":
            for sig in (resource.get("signals") or {}).values():
                if isinstance(sig, dict):
                    pins.update(collect_pins(sig))
        else:
            pin = resource.get("pin")
            if pin:
                pins.add(str(pin))
            for p in (resource.get("pins") or []):
                if p:
                    pins.add(str(p))
    else:
        from socfw.model.board import BoardScalarSignal, BoardVectorSignal, BoardResource, BoardConnectorRole
        if isinstance(resource, BoardScalarSignal):
            if resource.pin:
                pins.add(resource.pin)
        elif isinstance(resource, BoardVectorSignal):
            pin_vals = resource.pins.values() if isinstance(resource.pins, dict) else resource.pins
            pins.update(pin_vals)
        elif isinstance(resource, BoardResource):
            for sig in resource.scalars.values():
                pins.update(collect_pins(sig))
            for vec in resource.vectors.values():
                pins.update(collect_pins(vec))
        elif isinstance(resource, BoardConnectorRole):
            pin_vals = resource.pins.values() if isinstance(resource.pins, dict) else resource.pins
            pins.update(pin_vals)

    return pins
