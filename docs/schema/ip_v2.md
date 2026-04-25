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
