## Commit 55 — IP schema docs + lepšie `IPxxx` diagnostiky

Cieľ:

* vysvetliť presnú syntax `*.ip.yaml`
* jasne oddeliť canonical IP v2 od legacy/alternatívnych tvarov
* premeniť chyby typu `IP001`, `IP100`, `CLK002` na ľahko opraviteľné hlášky
* podporiť aliasy ako `interfaces: type: clock_output` → `clocking.outputs`

Názov commitu:

```text
docs: expand IP descriptor syntax and improve IP diagnostics
```

## Pridať

```text
docs/schema/ip_v2.md
docs/errors/ip_diagnostics.md
socfw/config/normalizers/ip.py
tests/unit/test_ip_normalizer_aliases.py
tests/unit/test_ip_diagnostics.py
```

## Upraviť

```text
socfw/config/ip_loader.py
socfw/config/schema_errors.py
socfw/validate/rules/ip_rules.py
socfw/validate/rules/clock_rules.py
socfw/schema_docs.py
```

---

# 1. `docs/schema/ip_v2.md`

Toto by som spravil ako hlavný referenčný dokument pre IP descriptor.

````md
# IP descriptor schema v2

An IP descriptor describes how a Verilog/SystemVerilog module is integrated into a `socfw` project.

Canonical file name examples:

```text
ip/blink_test.ip.yaml
ip/clkpll.ip.yaml
packs/vendor-intel/vendor/intel/pll/clkpll/ip.yaml
```

## Minimal canonical IP

```yaml
version: 2
kind: ip

ip:
  name: blink_test
  module: blink_test
  category: standalone

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: null
  active_high: null

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

ports:
  - name: SYS_CLK
    direction: input
    width: 1
  - name: ONB_LEDS
    direction: output
    width: 6

artifacts:
  synthesis:
    - ../rtl/blink_test.sv
  simulation: []
  metadata: []
```

## Required top-level keys

```yaml
version: 2
kind: ip
ip: ...
artifacts: ...
```

## `ip` section

```yaml
ip:
  name: blink_test
  module: blink_test
  category: standalone
```

Fields:

| Field | Required | Meaning |
|---|---:|---|
| `name` | yes | Logical IP type used by project modules |
| `module` | yes | RTL module name to instantiate |
| `category` | no | Human/category label: `standalone`, `clocking`, `memory`, `peripheral`, ... |

Project usage:

```yaml
modules:
  - instance: blink_01
    type: blink_test
```

Here `type: blink_test` must match `ip.name: blink_test`.

## `origin` section

```yaml
origin:
  kind: source
  packaging: plain_rtl
```

Common values:

```yaml
origin:
  kind: source
  packaging: plain_rtl
```

```yaml
origin:
  kind: generated
  packaging: quartus_ip
```

## `integration` section

```yaml
integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false
```

| Field | Meaning |
|---|---|
| `needs_bus` | IP expects a bus interface |
| `generate_registers` | framework should generate register block |
| `instantiate_directly` | IP appears as instance in top |
| `dependency_only` | files are exported but module is not instantiated |

## `reset` section

```yaml
reset:
  port: areset
  active_high: true
```

For IP without reset:

```yaml
reset:
  port: null
  active_high: null
```

## `clocking` section

```yaml
clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - name: c0
      domain_hint: clk_100mhz
      frequency_hz: 100000000
```

This is required for PLL-like IP.

Project generated clock reference:

```yaml
clocks:
  generated:
    - domain: clk_100mhz
      source:
        instance: clkpll
        output: c0
      frequency_hz: 100000000
```

The `output: c0` must exist in:

```yaml
clocking:
  outputs:
    - name: c0
```

## `ports` section

```yaml
ports:
  - name: inclk0
    direction: input
    width: 1
  - name: c0
    direction: output
    width: 1
```

Supported directions:

```text
input
output
inout
```

Ports are used by:

- bind validation
- width checks
- RTL instance generation
- default tie-offs for unconnected inputs

## `bus_interfaces` section

For bus-attached IP:

```yaml
bus_interfaces:
  - port_name: wb
    protocol: wishbone
    role: slave
    addr_width: 32
    data_width: 32
```

## `vendor` section

For Quartus/Intel generated IP:

```yaml
vendor:
  vendor: intel
  tool: quartus
  generator: ip_catalog
  family: cyclone_iv_e
  qip: files/clkpll.qip
  sdc:
    - files/clkpll.sdc
  filesets:
    - quartus_qip
    - timing_sdc
```

Vendor artifacts are exported into `hal/files.tcl`.

## `artifacts` section

```yaml
artifacts:
  synthesis:
    - files/clkpll.qip
    - files/clkpll.v
  simulation: []
  metadata: []
```

Rules:

- plain RTL files may be `.sv`, `.v`
- Quartus IP may include `.qip`
- `.qip` is emitted as `QIP_FILE`
- vendor SDC is emitted as `SDC_FILE`

## Deprecated aliases

Accepted temporarily with warning:

| Deprecated | Canonical |
|---|---|
| `config.needs_bus` | `integration.needs_bus` |
| `config.active_high_reset` | `reset.active_high` |
| `port_bindings.clock` | `clocking.primary_input_port` |
| `port_bindings.reset` | `reset.port` |
| `interfaces: type: clock_output` | `clocking.outputs` |
| `interfaces.signals` | `ports` and/or `clocking.outputs` |

## Common error examples

### `IP001`

Unknown IP type used by project.

```text
Project says: type: clkpll
But no descriptor with ip.name: clkpll was found.
```

Fix:

```yaml
registries:
  ip:
    - ip
```

and ensure:

```text
ip/clkpll.ip.yaml
```

contains:

```yaml
ip:
  name: clkpll
```

### `IP100`

IP descriptor YAML schema is invalid.

Usually means the descriptor shape is not canonical.

### `CLK002`

Generated clock references an output not declared in `clocking.outputs`.

Fix:

```yaml
clocking:
  outputs:
    - name: c0
```
````

---

# 2. `docs/errors/ip_diagnostics.md`

````md
# IP diagnostics

## IP001 — Unknown IP type

Example:

```text
ERROR IP001 project.modules
Unknown IP type 'clkpll' for instance 'clkpll'
```

Meaning:

`project.yaml` contains:

```yaml
modules:
  - instance: clkpll
    type: clkpll
```

but the IP catalog does not contain descriptor:

```yaml
ip:
  name: clkpll
```

Fix checklist:

1. Check `registries.ip`.
2. Check file name and path.
3. Check `ip.name`.
4. Run:

```bash
socfw doctor project.yaml
```

## IP100 — Invalid IP descriptor YAML schema

Meaning:

The descriptor exists, but does not match canonical v2 schema.

Common causes:

- missing `ip:` section
- using `interfaces:` instead of `clocking.outputs`
- using `config:` instead of `integration:`
- missing `artifacts.synthesis`

## IP101 — Missing artifact path

Meaning:

An artifact listed in `artifacts.synthesis` does not exist.

Example:

```yaml
artifacts:
  synthesis:
    - clkpll.qip
```

Fix:

Ensure the file exists relative to the IP descriptor file.

## IP200 — Missing declared port

Meaning:

Project bind references a port not listed in IP descriptor `ports:`.

Example:

```yaml
bind:
  ports:
    ONB_LEDS:
      target: board:onboard.leds
```

but IP descriptor lacks:

```yaml
ports:
  - name: ONB_LEDS
```

## CLK002 — Unknown generated clock output

Meaning:

Project generated clock says:

```yaml
source:
  instance: clkpll
  output: c0
```

but IP descriptor does not declare:

```yaml
clocking:
  outputs:
    - name: c0
```
````

---

# 3. `socfw/config/normalizers/ip.py`

Tu by som pridal alias podporu pre tvoj aktuálny `clkpll.ip.yaml`.

```python
from __future__ import annotations

from copy import deepcopy

from socfw.config.normalized import NormalizedDocument
from socfw.core.diagnostics import Diagnostic, Severity


def _warn(code: str, file: str, old: str, new: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=f"Deprecated IP descriptor alias `{old}` used; prefer `{new}`",
        subject="ip.alias",
        file=file,
        hints=(f"Replace `{old}` with `{new}`.",),
    )


def normalize_ip_document(data: dict, *, file: str) -> NormalizedDocument:
    d = deepcopy(data)
    diags: list[Diagnostic] = []
    aliases: list[str] = []

    d.setdefault("origin", {})
    d["origin"].setdefault("kind", "source")
    d["origin"].setdefault("packaging", "plain_rtl")

    d.setdefault("integration", {})
    d.setdefault("reset", {})
    d.setdefault("clocking", {})
    d.setdefault("artifacts", {})
    d["artifacts"].setdefault("synthesis", [])
    d["artifacts"].setdefault("simulation", [])
    d["artifacts"].setdefault("metadata", [])

    # config.needs_bus -> integration.needs_bus
    config = d.get("config")
    if isinstance(config, dict):
        if "needs_bus" in config and "needs_bus" not in d["integration"]:
            d["integration"]["needs_bus"] = bool(config["needs_bus"])
            diag = _warn("IP_ALIAS001", file, "config.needs_bus", "integration.needs_bus")
            diags.append(diag)
            aliases.append(diag.message)

        if "active_high_reset" in config and "active_high" not in d["reset"]:
            d["reset"]["active_high"] = config["active_high_reset"]
            diag = _warn("IP_ALIAS002", file, "config.active_high_reset", "reset.active_high")
            diags.append(diag)
            aliases.append(diag.message)

    # port_bindings.clock/reset
    port_bindings = d.get("port_bindings")
    if isinstance(port_bindings, dict):
        if "clock" in port_bindings and "primary_input_port" not in d["clocking"]:
            d["clocking"]["primary_input_port"] = port_bindings["clock"]
            diag = _warn("IP_ALIAS003", file, "port_bindings.clock", "clocking.primary_input_port")
            diags.append(diag)
            aliases.append(diag.message)

        if "reset" in port_bindings and "port" not in d["reset"]:
            d["reset"]["port"] = port_bindings["reset"]
            diag = _warn("IP_ALIAS004", file, "port_bindings.reset", "reset.port")
            diags.append(diag)
            aliases.append(diag.message)

    # interfaces clock_output -> clocking.outputs
    interfaces = d.get("interfaces")
    if isinstance(interfaces, list):
        outputs = list(d["clocking"].get("outputs") or [])
        ports = list(d.get("ports") or [])

        for iface in interfaces:
            if not isinstance(iface, dict):
                continue

            if iface.get("type") == "clock_output":
                for sig in iface.get("signals", []) or []:
                    if not isinstance(sig, dict):
                        continue

                    name = sig.get("name")
                    if not name:
                        continue

                    if not any(o.get("name") == name for o in outputs if isinstance(o, dict)):
                        outputs.append(
                            {
                                "name": name,
                                "domain_hint": sig.get("top_name"),
                                "frequency_hz": sig.get("frequency_hz"),
                            }
                        )

                    if not any(p.get("name") == name for p in ports if isinstance(p, dict)):
                        ports.append(
                            {
                                "name": name,
                                "direction": sig.get("direction", "output"),
                                "width": int(sig.get("width", 1)),
                            }
                        )

                diag = _warn("IP_ALIAS005", file, "interfaces[type=clock_output]", "clocking.outputs")
                diags.append(diag)
                aliases.append(diag.message)

        d["clocking"]["outputs"] = outputs
        d["ports"] = ports

    # ensure clock/reset ports are present in ports
    ports = list(d.get("ports") or [])

    clk_port = d.get("clocking", {}).get("primary_input_port")
    if clk_port and not any(p.get("name") == clk_port for p in ports if isinstance(p, dict)):
        ports.append({"name": clk_port, "direction": "input", "width": 1})

    rst_port = d.get("reset", {}).get("port")
    if rst_port and not any(p.get("name") == rst_port for p in ports if isinstance(p, dict)):
        ports.append({"name": rst_port, "direction": "input", "width": 1})

    d["ports"] = ports

    return NormalizedDocument(
        data=d,
        diagnostics=diags,
        aliases_used=aliases,
    )
```

---

# 4. Úprava `ip_loader.py`

Pridaj normalizer pred Pydantic validáciu:

```python
from socfw.config.normalizers.ip import normalize_ip_document
from socfw.config.schema_errors import ip_schema_error
```

V `load_file()`:

```python
raw = load_yaml_file(path)
if not raw.ok:
    return Result(diagnostics=raw.diagnostics)

data = raw.value or {}
norm = normalize_ip_document(data, file=path)
data = norm.data

try:
    doc = IpConfigSchema.model_validate(data)
except Exception as exc:
    return Result(diagnostics=norm.diagnostics + [ip_schema_error(exc, file=path)])
```

A pri úspechu:

```python
return Result(value=ipd, diagnostics=norm.diagnostics)
```

---

# 5. Lepšie `IP100` v `schema_errors.py`

Rozšír `ip_schema_error()`:

```python
def ip_schema_error(exc: Exception, *, file: str) -> Diagnostic:
    detail = format_pydantic_issue(exc)

    return Diagnostic(
        code="IP100",
        severity=Severity.ERROR,
        message="Invalid IP descriptor YAML schema",
        subject="ip",
        file=file,
        hints=(
            "Use canonical IP schema v2.",
            "Expected: version: 2, kind: ip, ip: { name, module, category }.",
            "Use `integration.needs_bus`, not `config.needs_bus`.",
            "Use `reset.port` and `reset.active_high`, not `port_bindings.reset` or `config.active_high_reset`.",
            "Use `clocking.primary_input_port` and `clocking.outputs` for clock-capable IP.",
            "Use `ports:` to declare RTL port names, directions and widths.",
            "Use `artifacts.synthesis:` for RTL/QIP files.",
            "Run `socfw explain-schema ip` for a canonical example.",
            f"Raw schema detail: {detail}",
        ),
    )
```

---

# 6. Lepšie `IP001` v `ip_rules.py`

Namiesto všeobecného textu daj praktický hint:

```python
class UnknownIpTypeRule(ValidationRule):
    def validate(self, system) -> list:
        diags = []
        known = ", ".join(sorted(system.ip_catalog.keys())) or "none"

        for idx, mod in enumerate(system.project.modules):
            if mod.type_name not in system.ip_catalog:
                diags.append(
                    Diagnostic(
                        code="IP001",
                        severity=Severity.ERROR,
                        message=f"Unknown IP type '{mod.type_name}' for instance '{mod.instance}'",
                        subject="project.modules",
                        file=system.sources.project_file,
                        path=f"modules[{idx}].type",
                        hints=(
                            f"Project module `{mod.instance}` uses `type: {mod.type_name}`.",
                            "That value must match `ip.name` in one loaded *.ip.yaml descriptor.",
                            "Check `registries.ip` paths in project.yaml.",
                            "Check `registries.packs` if the IP should come from a pack.",
                            f"Known IP descriptors: {known}",
                            "Run `socfw doctor project.yaml` to inspect loaded IP catalog.",
                        ),
                    )
                )

        return diags
```

---

# 7. Lepšie `CLK002` v clock validation

Ak máš pravidlo, ktoré hlási:

```text
Generated clock 'clk_100mhz' references unknown output 'c0' on IP 'clkpll'
```

rozšír ho o hinty:

```python
Diagnostic(
    code="CLK002",
    severity=Severity.ERROR,
    message=f"Generated clock '{domain}' references unknown output '{output}' on IP '{type_name}'",
    subject="project.clocks.generated",
    file=system.sources.project_file,
    path=f"clocks.generated[{idx}].source.output",
    hints=(
        f"Module instance `{instance}` has type `{type_name}`.",
        f"IP descriptor `{type_name}` must declare this clock output:",
        "clocking:",
        "  outputs:",
        f"    - name: {output}",
        "      frequency_hz: <Hz>",
        "If your descriptor uses `interfaces: type: clock_output`, convert it to `clocking.outputs` or enable IP alias normalization.",
    ),
)
```

---

# 8. `tests/unit/test_ip_normalizer_aliases.py`

```python
from socfw.config.normalizers.ip import normalize_ip_document


def test_ip_normalizer_converts_clock_output_interfaces():
    norm = normalize_ip_document(
        {
            "version": 2,
            "kind": "ip",
            "ip": {
                "name": "clkpll",
                "module": "clkpll",
                "category": "clock",
            },
            "artifacts": {
                "synthesis": ["clkpll.qip"],
            },
            "port_bindings": {
                "clock": "inclk0",
                "reset": "areset",
            },
            "config": {
                "active_high_reset": True,
                "needs_bus": False,
            },
            "interfaces": [
                {
                    "type": "clock_output",
                    "signals": [
                        {
                            "name": "c0",
                            "direction": "output",
                            "width": 1,
                            "top_name": "clk_100mhz",
                        }
                    ],
                }
            ],
        },
        file="clkpll.ip.yaml",
    )

    assert norm.data["clocking"]["primary_input_port"] == "inclk0"
    assert norm.data["reset"]["port"] == "areset"
    assert norm.data["reset"]["active_high"] is True
    assert norm.data["clocking"]["outputs"][0]["name"] == "c0"
    assert any(p["name"] == "c0" for p in norm.data["ports"])
    assert any("interfaces" in a for a in norm.aliases_used)
```

---

# 9. `tests/unit/test_ip_diagnostics.py`

```python
from pydantic import BaseModel, ValidationError

from socfw.config.schema_errors import ip_schema_error


class DemoSchema(BaseModel):
    ip: dict


def test_ip_schema_error_mentions_clocking_outputs_and_ports():
    try:
        DemoSchema.model_validate({})
    except ValidationError as exc:
        d = ip_schema_error(exc, file="bad.ip.yaml")

    assert d.code == "IP100"
    assert any("clocking.outputs" in h for h in d.hints)
    assert any("ports:" in h for h in d.hints)
    assert any("socfw explain-schema ip" in h for h in d.hints)
```

---

# 10. `socfw/schema_docs.py`

Rozšír `ip` doc na canonical tvar vrátane `clocking.outputs` a `ports`.

Minimálne nahraď IP blok týmto:

```python
"ip": """# ip.yaml v2

Canonical shape:

version: 2
kind: ip

ip:
  name: clkpll
  module: clkpll
  category: clocking

origin:
  kind: generated
  packaging: quartus_ip

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: areset
  active_high: true

clocking:
  primary_input_port: inclk0
  additional_input_ports: []
  outputs:
    - name: c0
      domain_hint: clk_100mhz
      frequency_hz: 100000000

ports:
  - name: inclk0
    direction: input
    width: 1
  - name: areset
    direction: input
    width: 1
  - name: c0
    direction: output
    width: 1

artifacts:
  synthesis:
    - clkpll.qip
  simulation: []
  metadata: []
""",
```

---

# 11. Praktický výsledok pre tvoje `clkpll.ip.yaml`

Po tomto commite budú fungovať dve veci:

## Canonical tvar

```yaml
clocking:
  outputs:
    - name: c0
```

## Dočasne aj legacy/alias tvar

```yaml
interfaces:
  - type: clock_output
    signals:
      - name: c0
```

ale vypíše warning:

```text
WARNING IP_ALIAS005 ip.alias
Deprecated IP descriptor alias `interfaces[type=clock_output]` used; prefer `clocking.outputs`
```

---

# 12. Definition of Done

Commit 55 je hotový, keď:

* `docs/schema/ip_v2.md` detailne opisuje IP descriptor syntax
* `docs/errors/ip_diagnostics.md` opisuje `IPxxx` chyby
* IP normalizer prekladá `interfaces[type=clock_output]` na `clocking.outputs`
* `IP100` dáva použiteľné hinty
* `IP001` dáva použiteľné hinty
* `CLK002` ukáže presný fix v `clocking.outputs`
* tvoj `clkpll.ip.yaml` buď prejde canonical formou, alebo alias formou s warningom

Ďalší commit:

```text
validate: add board resource schema docs and BRDxxx diagnostics
```
