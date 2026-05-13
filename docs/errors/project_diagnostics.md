# Project diagnostics

## PRJ002 — Unknown IP type

Example:

```text
ERROR PRJ002 project.modules
Unknown IP type 'uart_stream_loopback_status' for instance 'uart_loopback0'
```

Meaning:

`project.yaml` contains a `modules` entry with a `type:` that was not found
in any registered IP catalog or local `ip/` directory.

Fix checklist:

1. Check `registries.ip` includes the directory containing the descriptor.
2. Check the `.ip.yaml` file exists and `ip.name` matches the `type:` value.
3. Run `socfw validate project.yaml` to see the full search paths.

---

## PRJ101 — Project model validation error

Meaning:

The project model has an internal inconsistency, e.g.:

- duplicate module instance name
- duplicate clock binding port on a module
- duplicate port binding on a module
- duplicate generated clock domain name
- duplicate bus fabric name

Fix: Correct the duplicate entry in `project.yaml`.

---

## RST001 — Reset declared but no IP consumes it

Example:

```text
WARNING RST001 project.modules
Board reset 'RESET_N' is declared but no instantiated IP has a reset port
```

Meaning:

The board defines a reset signal, but none of the instantiated IP modules
have a `reset.port` in their descriptor. The framework will not emit the
reset port or `assign reset_n = RESET_N` in the generated RTL.

Fix:

- If the design intentionally has no reset: remove the reset from the board timing config.
- If IP should have reset: add `reset:` section to the IP descriptor.

---

## RST010 — reset_driver format invalid

Example:

```text
ERROR RST010 project.reset_driver
reset_driver 'rst_sync0' must be in 'instance.port' format
```

Meaning:

The `reset_driver:` field must specify both an instance name and a port name
separated by a dot.

Fix:

```yaml
reset_driver: rst_sync0.rst_no   # correct
# not:
reset_driver: rst_sync0          # wrong — missing port name
```

---

## RST011 — reset_driver references unknown instance

Example:

```text
ERROR RST011 project.reset_driver
reset_driver references unknown instance 'rst_sync0'
```

Meaning:

The instance named in `reset_driver:` does not exist in `modules:`.

Fix:

Add the instance to `modules:`:

```yaml
modules:
  - instance: rst_sync0
    type: cdc_reset_synchronizer
    reset: null
    params:
      STAGES: 3
```

---

## RST012 — reset_driver references unknown port

Example:

```text
ERROR RST012 project.reset_driver
reset_driver references unknown port 'rst_no' on instance 'rst_sync0' (type 'cdc_reset_synchronizer')
```

Meaning:

The port named in `reset_driver:` does not appear in the IP descriptor's `ports:` list.

Fix:

Ensure the IP descriptor declares the port:

```yaml
ports:
  - name: rst_no
    direction: output
    width: 1
```

Or correct the port name in `project.yaml`.

---

## RST013 — reset_driver port is not an output

Example:

```text
ERROR RST013 project.reset_driver
reset_driver port 'rst_sync0.rst_ni' is 'input', must be 'output'
```

Meaning:

The port named in `reset_driver:` is an input port on the IP module.
Only an output port can drive `reset_n`.

Fix:

Use an output port. For `cdc_reset_synchronizer`, the correct port is `rst_no` (output),
not `rst_ni` (input).

---

## RST014 — reset_driver port is not 1-bit

Example:

```text
ERROR RST014 project.reset_driver
reset_driver port 'rst_sync0.rst_no' has width 4, must be 1
```

Meaning:

The reset driver port must be a single-bit signal.

Fix:

Use a 1-bit output port, or check the IP descriptor port width.

---

## RST020 — reset override on IP with no reset port

Example:

```text
WARNING RST020 project.modules.rst_sync0
Module 'rst_sync0' has reset: 'null' but IP 'cdc_reset_synchronizer' declares no reset port —
the expression will be ignored
```

Meaning:

A `reset:` override was specified on a module instance whose IP descriptor has
`reset.port: null`. The override has no effect because there is no port to connect.

This warning is informational — it may indicate a misconfiguration or a harmless
explicit annotation. No RTL change results from this.

Fix (to suppress the warning):

Remove `reset:` from the module instance, or add a `reset.port:` to the IP descriptor
if the module actually has one.

---

## CLK001 — Generated clock references unknown instance

Example:

```text
ERROR CLK001 project.clocks.generated
Generated clock 'pll_clk' references unknown instance 'clkpll'
```

Meaning:

`clocks.generated[].source.instance` names a module instance that does not exist in `modules:`.

Fix: Add the instance or correct the name.

---

## CLK002 — Generated clock references unknown output port

Example:

```text
ERROR CLK002 project.clocks.generated
Generated clock 'pll_clk' references unknown output 'c0' on IP 'clkpll'
```

Meaning:

The IP descriptor for the source instance does not declare the named output in `clocking.outputs`.

Fix:

```yaml
# in clkpll.ip.yaml:
clocking:
  outputs:
    - port: c0
      kind: generated_clock
      domain: pll_clk
```

---

## CLK003 — Clock output is not a generated_clock

Example:

```text
ERROR CLK003 project.clocks.generated
Output 'c0' on IP 'clkpll' is 'clock_output', not a generated_clock
```

Meaning:

The referenced output exists in the IP descriptor but has `kind:` other than `generated_clock`.

Fix:

```yaml
clocking:
  outputs:
    - port: c0
      kind: generated_clock   # must be this exact value
```

---

## TIM201 — IO delay max set without min

Example:

```text
WARNING TIM201 timing.io_delays
Input max IO delay is set but input min IO delay is missing
```

Meaning:

`timing.yaml` defines `default_input_max_ns` (or `default_output_max_ns`) but no
corresponding minimum. Quartus uses `set_input_delay` / `set_output_delay` with
both `-max` and `-min` flags. Without a min, the hold-time side is unconstrained.

Fix:

```yaml
io_delays:
  default_input_max_ns: 2.0
  default_input_min_ns: 0.5
  default_output_max_ns: 2.0
  default_output_min_ns: 0.5
```

---

## PIN001 — Pin conflict between features

Example:

```text
ERROR PIN001 project.features.use
pin D2 selected by both board:onboard.uart and board:onboard.uart.rx
```

Meaning:

Two entries in `features.use` both claim ownership of the same physical pin.

Fix:

Use either the bundle reference or the individual sub-signal reference, not both:

```yaml
features:
  use:
    - board:onboard.uart.rx
    - board:onboard.uart.tx
    # do NOT also add board:onboard.uart here
```
