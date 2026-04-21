from __future__ import annotations
from abc import ABC, abstractmethod
from typing import Any

from socfw.elaborate.bus_plan import InterconnectPlan


class BusPlanner(ABC):
    protocol: str

    @abstractmethod
    def plan(self, system: Any) -> InterconnectPlan:
        raise NotImplementedError
