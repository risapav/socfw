from __future__ import annotations

from socfw.validate.rules.base import ValidationRule


class DuplicateCatalogEntryWarningRule(ValidationRule):
    def validate(self, system) -> list:
        # V1 placeholder: duplicate detection is better implemented during indexing.
        return []
