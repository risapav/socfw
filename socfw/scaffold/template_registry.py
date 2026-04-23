from __future__ import annotations

from socfw.scaffold.templates import ScaffoldTemplate


class TemplateRegistry:
    def all(self) -> list[ScaffoldTemplate]:
        return [
            ScaffoldTemplate(
                key="blink",
                title="Standalone blink",
                mode="standalone",
                description="Minimal standalone blink project.",
                defaults={"cpu": None, "firmware": False},
            ),
            ScaffoldTemplate(
                key="soc-led",
                title="Simple SoC LED demo",
                mode="soc",
                description="simple_bus SoC with RAM and GPIO.",
                defaults={"cpu": "dummy_cpu", "firmware": False},
            ),
            ScaffoldTemplate(
                key="picorv32-soc",
                title="PicoRV32 SoC",
                mode="soc",
                description="PicoRV32 + RAM + GPIO + firmware flow.",
                defaults={"cpu": "picorv32_min", "firmware": True},
            ),
            ScaffoldTemplate(
                key="axi-bridge",
                title="AXI-lite bridge demo",
                mode="soc",
                description="simple_bus SoC with AXI-lite bridged peripheral.",
                defaults={"cpu": "picorv32_min", "firmware": True},
            ),
            ScaffoldTemplate(
                key="wishbone-bridge",
                title="Wishbone bridge demo",
                mode="soc",
                description="simple_bus SoC with Wishbone bridged peripheral.",
                defaults={"cpu": "dummy_cpu", "firmware": False},
            ),
        ]

    def get(self, key: str) -> ScaffoldTemplate | None:
        for t in self.all():
            if t.key == key:
                return t
        return None
