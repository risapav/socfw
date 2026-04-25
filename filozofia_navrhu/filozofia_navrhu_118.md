## Commit 54 — RTL emitter používa IP port descriptors

Cieľ:

* generovať bezpečnejšie module connections
* pripájať deklarované porty deterministicky
* nevynechať nepoužité porty náhodne
* pripraviť základ pre neskoršie lint pravidlá

Názov commitu:

```text
rtl: use IP port descriptors to emit safer module connections
```

## Upraviť

```text
socfw/builders/rtl_ir_builder.py
socfw/emit/rtl_emitter.py
tests/unit/test_rtl_ir_builder_ports.py
tests/integration/test_build_blink_converged.py
tests/integration/test_build_vendor_sdram_soc.py
```

---

## Zmena v `RtlIrBuilder`

Pri inštancovaní IP modulu:

1. najprv zostav mapu explicitných spojení:

   * clocks
   * reset
   * board binds
2. potom prejdi `ip.ports`
3. každý port emitni:

   * ak má explicitné spojenie → použi ho
   * ak je `input` a nemá spojenie → bezpečná default hodnota
   * ak je `output/inout` a nemá spojenie → otvorené spojenie

---

## Helpery do `rtl_ir_builder.py`

```python
def _default_expr_for_port(self, port) -> str:
    if port.direction != "input":
        return ""

    if port.width == 1:
        return "1'b0"

    return f"{port.width}'h0"


def _connections_from_declared_ports(self, ip, explicit: dict[str, str]) -> tuple[RtlConnection, ...]:
    conns = []

    if getattr(ip, "ports", None):
        for p in sorted(ip.ports, key=lambda x: x.name):
            expr = explicit.get(p.name)
            if expr is None:
                expr = self._default_expr_for_port(p)
            conns.append(RtlConnection(p.name, expr))
        return tuple(conns)

    # fallback for old descriptors without ports
    return tuple(
        RtlConnection(name, expr)
        for name, expr in sorted(explicit.items())
    )
```

---

## Úprava `_add_project_module_instances`

Namiesto priameho `conns.append(...)` používaj `explicit`.

```python
def _add_project_module_instances(self, system, top: RtlTop) -> None:
    for mod in system.project.modules:
        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue

        explicit: dict[str, str] = {}

        for port_name, domain in sorted(mod.clocks.items()):
            if isinstance(domain, str):
                explicit[port_name] = self._clock_expr(system, domain)

        if ip.reset_port:
            explicit[ip.reset_port] = "reset_n"

        ports = mod.bind.get("ports", {}) if isinstance(mod.bind, dict) else {}
        for port_name, bind_spec in sorted(ports.items()):
            if not isinstance(bind_spec, dict):
                continue
            target = bind_spec.get("target")
            if not isinstance(target, str):
                continue
            if target.startswith("board:"):
                resource = system.board.resolve_resource_path(target[len("board:"):])
                if isinstance(resource, dict) and resource.get("top_name"):
                    explicit[port_name] = resource["top_name"]

        top.instances.append(
            RtlInstance(
                module=ip.module,
                instance=mod.instance,
                connections=self._connections_from_declared_ports(ip, explicit),
            )
        )
```

---

## Prečo je toto lepšie

Predtým sa emitovali len porty, ktoré boli v `clocks` alebo `bind`.

Po tomto commite:

* descriptor je source of truth
* všetky deklarované porty majú stabilné poradie
* input porty bez bindu nedostanú náhodný floating input
* outputy bez bindu sú otvorené

---

## Unit test `tests/unit/test_rtl_ir_builder_ports.py`

```python
from socfw.builders.rtl_ir_builder import RtlIrBuilder
from socfw.model.board import BoardClock, BoardModel
from socfw.model.ip import IpDescriptor
from socfw.model.ports import PortDescriptor
from socfw.model.project import ProjectModel, ProjectModule
from socfw.model.system import SystemModel


def test_rtl_ir_builder_uses_declared_ports_with_defaults():
    system = SystemModel(
        board=BoardModel(
            board_id="demo",
            system_clock=BoardClock(
                id="clk",
                top_name="SYS_CLK",
                pin="A1",
                frequency_hz=50_000_000,
            ),
        ),
        project=ProjectModel(
            name="demo",
            mode="standalone",
            board_ref="demo",
            modules=[
                ProjectModule(
                    instance="u0",
                    type_name="demo_ip",
                    clocks={"clk": "sys_clk"},
                )
            ],
        ),
        ip_catalog={
            "demo_ip": IpDescriptor(
                name="demo_ip",
                module="demo_ip",
                category="test",
                ports=(
                    PortDescriptor(name="clk", direction="input", width=1),
                    PortDescriptor(name="enable", direction="input", width=1),
                    PortDescriptor(name="data_in", direction="input", width=8),
                    PortDescriptor(name="done", direction="output", width=1),
                ),
            )
        },
    )

    top = RtlIrBuilder().build(system=system, planned_bridges=[])
    inst = top.instances[0]

    conns = {c.port: c.expr for c in inst.connections}
    assert conns["clk"] == "SYS_CLK"
    assert conns["enable"] == "1'b0"
    assert conns["data_in"] == "8'h0"
    assert conns["done"] == ""
```

---

## Integration očakávania

### Blink

`rtl/soc_top.sv` má obsahovať:

```systemverilog
blink_test blink_test (
  .ONB_LEDS(ONB_LEDS),
  .SYS_CLK(SYS_CLK)
);
```

alebo podľa zoradenia portov:

```systemverilog
  .ONB_LEDS(ONB_LEDS),
  .SYS_CLK(SYS_CLK)
```

### SDRAM

`sdram_ctrl sdram0` má mať deklarované všetky porty z descriptoru:

```systemverilog
.zs_addr(ZS_ADDR)
.zs_dq(ZS_DQ)
.zs_clk(ZS_CLK)
```

a bus/Wishbone porty zatiaľ default/open:

```systemverilog
.wb_adr()
.wb_dat_r()
```

To je v poriadku, kým nedokončíš real bus wiring.

---

## Golden update

```bash
socfw build tests/golden/fixtures/blink_converged/project.yaml --out build/blink_converged
socfw build tests/golden/fixtures/vendor_sdram_soc/project.yaml --out build/vendor_sdram_soc

cp build/blink_converged/rtl/soc_top.sv tests/golden/expected/blink_converged/rtl/soc_top.sv
cp build/vendor_sdram_soc/rtl/soc_top.sv tests/golden/expected/vendor_sdram_soc/rtl/soc_top.sv
```

---

## Čo ešte nerobiť

Ešte nerob:

* bus signal wiring
* address decoder
* automatic output net declarations
* tri-state policy for `inout`
* reset synchronizer

Tento commit len využíva port descriptors na stabilnejšie module instantiation.

---

## Definition of Done

Commit 54 je hotový, keď:

* `RtlIrBuilder` používa `ip.ports`
* inputy bez bindu majú default hodnoty
* outputy/inouty bez bindu sú otvorené
* blink a SDRAM top snapshoty sú aktualizované
* testy sú green

Ďalší commit:

```text
rtl: add native bus signal declarations and bridge-to-sdram wishbone wiring
```
