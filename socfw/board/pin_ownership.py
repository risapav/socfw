from __future__ import annotations

from dataclasses import dataclass

from socfw.board.feature_expansion import SelectedResources
from socfw.board.resource_tree import iter_resource_leaves
from socfw.model.board import BoardModel


@dataclass(frozen=True)
class PinUse:
    pin: str
    resource_path: str
    bit: int | None
    top_name: str


def collect_pin_ownership(
    board: BoardModel,
    selected: SelectedResources,
) -> list[PinUse]:
    """
    For each selected resource, produce PinUse entries for every physical pin.
    """
    result: list[PinUse] = []

    for path in selected:
        if path.startswith("onboard."):
            sub = path[len("onboard."):]
            parts = sub.split(".", 1)
            res_key = parts[0]
            res = board.onboard.get(res_key)
            if res is None:
                continue

            for sig in res.scalars.values():
                result.append(PinUse(pin=sig.pin, resource_path=path, bit=None, top_name=sig.top_name))

            for vec in res.vectors.values():
                for idx, pin in sorted(vec.pins.items()):
                    result.append(PinUse(
                        pin=pin,
                        resource_path=path,
                        bit=idx,
                        top_name=vec.top_name,
                    ))

        elif path.startswith("external."):
            sub = path[len("external."):]
            external = board.resources.get("external") or {}

            for leaf_path, node in iter_resource_leaves(external, sub):
                if not isinstance(node, dict):
                    continue
                kind = node.get("kind", "scalar")
                top_name = node.get("top_name", leaf_path)
                full_path = f"external.{leaf_path}"

                if kind == "scalar":
                    pin = node.get("pin")
                    if pin:
                        result.append(PinUse(pin=str(pin), resource_path=full_path, bit=None, top_name=top_name))

                elif kind in ("vector", "inout"):
                    pins = node.get("pins") or []
                    if isinstance(pins, dict):
                        items = sorted(pins.items())
                    else:
                        items = list(enumerate(pins))
                    for idx, pin in items:
                        if pin:
                            result.append(PinUse(pin=str(pin), resource_path=full_path, bit=idx, top_name=top_name))

    return result
