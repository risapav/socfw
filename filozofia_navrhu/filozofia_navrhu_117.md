## Commit 53 — board binding width + direction checks

Cieľ:

* zachytiť chyby v `bind.ports`
* overiť, že IP port a board resource majú kompatibilnú šírku
* overiť základný smer:

  * `output` IP port → board output resource
  * `inout` IP port → board inout resource
* pripraviť pevnejší základ pre SDRAM a širšie externé rozhrania

Názov commitu:

```text
validate: add board binding width and direction checks
```

## Pridať

```text
socfw/model/ports.py
socfw/validate/rules/binding_rules.py
tests/unit/test_binding_rules.py
```

## Upraviť

```text
socfw/model/ip.py
socfw/config/ip_schema.py
socfw/config/ip_loader.py
socfw/validate/runner.py
packs/vendor-intel/vendor/intel/sdram/sdram_ctrl/ip.yaml
tests/golden/fixtures/blink_converged/ip/blink_test.ip.yaml
```

---

## `socfw/model/ports.py`

```python
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class PortDescriptor:
    name: str
    direction: str
    width: int = 1
```

---

## `socfw/model/ip.py`

Doplň do `IpDescriptor`:

```python
from socfw.model.ports import PortDescriptor
```

a pole:

```python
ports: tuple[PortDescriptor, ...] = ()
```

plus helper:

```python
def port_by_name(self, name: str) -> PortDescriptor | None:
    for p in self.ports:
        if p.name == name:
            return p
    return None
```

---

## `socfw/config/ip_schema.py`

Pridaj:

```python
class IpPortSchema(BaseModel):
    name: str
    direction: str
    width: int = 1
```

A do `IpConfigSchema`:

```python
ports: list[IpPortSchema] = Field(default_factory=list)
```

---

## `socfw/config/ip_loader.py`

Import:

```python
from socfw.model.ports import PortDescriptor
```

Pri skladaní `IpDescriptor`:

```python
ports=tuple(
    PortDescriptor(
        name=p.name,
        direction=p.direction,
        width=p.width,
    )
    for p in doc.ports
),
```

---

## Príklad update `blink_test.ip.yaml`

```yaml
ports:
  - name: SYS_CLK
    direction: input
    width: 1
  - name: ONB_LEDS
    direction: output
    width: 6
```

---

## Príklad update `sdram_ctrl/ip.yaml`

```yaml
ports:
  - name: clk
    direction: input
    width: 1
  - name: reset_n
    direction: input
    width: 1

  - name: zs_addr
    direction: output
    width: 13
  - name: zs_ba
    direction: output
    width: 2
  - name: zs_dq
    direction: inout
    width: 16
  - name: zs_dqm
    direction: output
    width: 2
  - name: zs_cs_n
    direction: output
    width: 1
  - name: zs_we_n
    direction: output
    width: 1
  - name: zs_ras_n
    direction: output
    width: 1
  - name: zs_cas_n
    direction: output
    width: 1
  - name: zs_cke
    direction: output
    width: 1
  - name: zs_clk
    direction: output
    width: 1
```

---

## `socfw/validate/rules/binding_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class BoardBindingRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []

        for midx, mod in enumerate(system.project.modules):
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue

            ports = mod.bind.get("ports", {}) if isinstance(mod.bind, dict) else {}

            for port_name, bind_spec in sorted(ports.items()):
                if not isinstance(bind_spec, dict):
                    continue

                target = bind_spec.get("target")
                if not isinstance(target, str) or not target.startswith("board:"):
                    continue

                board_path = target[len("board:"):]
                resource = system.board.resolve_resource_path(board_path)

                if not isinstance(resource, dict):
                    diags.append(
                        Diagnostic(
                            code="BIND001",
                            severity=Severity.ERROR,
                            message=f"Unknown board binding target '{target}'",
                            subject="project.bind",
                            file=system.sources.project_file,
                            path=f"modules[{midx}].bind.ports.{port_name}",
                            hints=("Check that the board resource exists in the selected board YAML.",),
                        )
                    )
                    continue

                ip_port = ip.port_by_name(port_name)

                if ip_port is None:
                    diags.append(
                        Diagnostic(
                            code="BIND002",
                            severity=Severity.ERROR,
                            message=f"IP '{ip.name}' has no declared port '{port_name}'",
                            subject="project.bind",
                            file=system.sources.project_file,
                            path=f"modules[{midx}].bind.ports.{port_name}",
                            hints=("Add the port to the IP descriptor `ports:` section or fix the bind port name.",),
                        )
                    )
                    continue

                res_width = int(resource.get("width", 1))
                if ip_port.width != res_width:
                    diags.append(
                        Diagnostic(
                            code="BIND003",
                            severity=Severity.ERROR,
                            message=(
                                f"Width mismatch for bind {mod.instance}.{port_name}: "
                                f"IP port width {ip_port.width}, board resource width {res_width}"
                            ),
                            subject="project.bind",
                            file=system.sources.project_file,
                            path=f"modules[{midx}].bind.ports.{port_name}",
                            hints=("Make the IP port width match the board resource width.",),
                        )
                    )

                res_kind = resource.get("kind", "scalar")
                if ip_port.direction == "inout" and res_kind != "inout":
                    diags.append(
                        Diagnostic(
                            code="BIND004",
                            severity=Severity.ERROR,
                            message=(
                                f"Direction mismatch for bind {mod.instance}.{port_name}: "
                                f"IP port is inout but board resource kind is {res_kind}"
                            ),
                            subject="project.bind",
                            file=system.sources.project_file,
                            path=f"modules[{midx}].bind.ports.{port_name}",
                            hints=("Bind inout ports only to board resources with kind: inout.",),
                        )
                    )

                if ip_port.direction in {"output", "input"} and res_kind == "inout":
                    # allow output/input to inout only later when tri-state policy exists
                    if ip_port.direction != "inout":
                        diags.append(
                            Diagnostic(
                                code="BIND005",
                                severity=Severity.WARNING,
                                message=(
                                    f"Port {mod.instance}.{port_name} direction {ip_port.direction} "
                                    f"is bound to inout board resource"
                                ),
                                subject="project.bind",
                                file=system.sources.project_file,
                                path=f"modules[{midx}].bind.ports.{port_name}",
                                hints=("This may require explicit tri-state handling in a later flow.",),
                            )
                        )

        return diags
```

---

## `socfw/validate/runner.py`

Pridaj:

```python
from socfw.validate.rules.binding_rules import BoardBindingRule
```

Do rules:

```python
BoardBindingRule(),
```

ideálne po `UnknownIpTypeRule()`.

---

## `tests/unit/test_binding_rules.py`

```python
from socfw.model.board import BoardClock, BoardModel
from socfw.model.ip import IpDescriptor
from socfw.model.ports import PortDescriptor
from socfw.model.project import ProjectModel, ProjectModule
from socfw.model.source_context import SourceContext
from socfw.model.system import SystemModel
from socfw.validate.rules.binding_rules import BoardBindingRule


def _system(ip_port):
    return SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(
                id="clk",
                top_name="SYS_CLK",
                pin="A1",
                frequency_hz=50_000_000,
            ),
            resources={
                "onboard": {
                    "leds": {
                        "kind": "vector",
                        "top_name": "ONB_LEDS",
                        "width": 6,
                        "pins": ["P1", "P2", "P3", "P4", "P5", "P6"],
                    }
                }
            },
        ),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[
                ProjectModule(
                    instance="blink",
                    type_name="blink_test",
                    bind={
                        "ports": {
                            "ONB_LEDS": {
                                "target": "board:onboard.leds",
                            }
                        }
                    },
                )
            ],
        ),
        ip_catalog={
            "blink_test": IpDescriptor(
                name="blink_test",
                module="blink_test",
                category="standalone",
                ports=(ip_port,),
            )
        },
        sources=SourceContext(project_file="project.yaml"),
    )


def test_binding_width_match_passes():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="ONB_LEDS", direction="output", width=6))
    )
    assert not any(d.code == "BIND003" for d in diags)


def test_binding_width_mismatch_reports_error():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="ONB_LEDS", direction="output", width=4))
    )
    assert any(d.code == "BIND003" for d in diags)


def test_missing_ip_port_reports_error():
    diags = BoardBindingRule().validate(
        _system(PortDescriptor(name="OTHER", direction="output", width=6))
    )
    assert any(d.code == "BIND002" for d in diags)
```

---

## Definition of Done

Commit 53 je hotový, keď:

* IP descriptors môžu deklarovať `ports`
* bind validation overí existenciu portu
* bind validation overí width mismatch
* SDRAM `zs_dq` je rozpoznané ako `inout`
* testy sú green

Ďalší commit:

```text
rtl: use IP port descriptors to emit safer module connections
```
