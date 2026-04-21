from __future__ import annotations
from abc import ABC, abstractmethod

from socfw.core.diagnostics import Diagnostic
from socfw.model.system import SystemModel


class ValidationRule(ABC):
    @abstractmethod
    def validate(self, system: SystemModel) -> list[Diagnostic]:
        raise NotImplementedError
