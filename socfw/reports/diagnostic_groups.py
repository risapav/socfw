from __future__ import annotations

from collections import defaultdict


class DiagnosticGrouper:
    def group_by_category(self, diags):
        groups = defaultdict(list)
        for d in diags:
            groups[d.category].append(d)
        return dict(groups)
