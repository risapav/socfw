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
WARNING RST001 project
Board reset 'RESET_N' is declared but no instantiated IP has a reset port
```

Meaning:

The board defines a reset signal, but none of the instantiated IP modules
have a `reset.port` in their descriptor. The framework will not emit the
reset port, `reset_n`, or `RESET_N` pin in the generated RTL, to avoid
Quartus "object assigned but never read" warnings.

Fix:

- If the design intentionally has no reset: remove the reset from the board timing config.
- If IP should have reset: add `reset:` section to the IP descriptor.

---

## CLK003 — Unknown generated clock output

Example:

```text
ERROR CLK003 project
Output 'c0' on IP 'clkpll' not declared in clocking.outputs
```

Meaning:

`project.yaml` has:

```yaml
clocks:
  generated:
    - domain: sys_pll_clk
      source:
        instance: clkpll
        output: c0
```

but the IP descriptor for `clkpll` does not list `c0` in `clocking.outputs`.

Fix:

```yaml
clocking:
  outputs:
    - name: c0
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

Add `default_input_min_ns` / `default_output_min_ns` to `io_delays`:

```yaml
io_delays:
  default_input_max_ns: 2.0
  default_input_min_ns: 0.5
  default_output_max_ns: 2.0
  default_output_min_ns: 0.5
```

Or add per-port `min_ns` under `overrides:`.

---

## PIN001 — Pin conflict between features

Example:

```text
ERROR PIN001 project.features.use
pin D2 selected by both board:onboard.uart and board:onboard.uart.rx
```

Meaning:

Two entries in `features.use` both claim ownership of the same physical pin.
This can happen when a parent resource (e.g. `board:onboard.uart`) and a
sub-signal resource (e.g. `board:onboard.uart.rx`) are both selected — the
parent claims all pins of the bundle.

Fix:

Use either the bundle reference or the individual sub-signal reference, not both:

```yaml
features:
  use:
    - board:onboard.uart.rx   # claim only RX pin
    - board:onboard.uart.tx   # claim only TX pin
    # do NOT also add board:onboard.uart here
```
