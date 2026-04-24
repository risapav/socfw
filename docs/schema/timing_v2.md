# Timing Configuration Schema v2

Canonical YAML structure for timing constraint files. Legacy top-level keys are accepted with deprecation warnings.

## Top-level structure

```yaml
timing:
  clocks:
    - name: <string>
      source: <port>
      period_ns: <float>
      uncertainty_ns: <float>         # optional
      reset:
        source: <port>
        active_low: <bool>            # default: true
        sync_stages: <int>            # default: 2

  generated_clocks:
    - name: <string>
      source:
        instance: <string>
        output: <string>
      pin_index: <int>                # optional
      multiply_by: <int>              # optional
      divide_by: <int>                # optional
      phase_shift_ps: <int>           # optional
      reset_sync_from: <string>       # optional
      reset_sync_stages: <int>        # optional

  clock_groups:
    - type: asynchronous | exclusive
      groups: [[<clock>, ...], ...]

  io_delays:
    auto: <bool>                      # default: true
    default_clock: <string>
    default_input_max_ns: <float>
    default_output_max_ns: <float>
    overrides:
      - port: <string>
        direction: input | output
        clock: <string>
        max_ns: <float>
        min_ns: <float>               # optional
        comment: <string>             # optional

  false_paths:
    - from_port: <string>             # optional
      from_clock: <string>            # optional
      to_clock: <string>              # optional
      from_cell: <string>             # optional
      to_cell: <string>               # optional
      comment: <string>               # optional

  derive_uncertainty: <bool>          # default: false
```

## Deprecated aliases (v1 → v2)

| Deprecated key | Canonical key | Warning code |
|---|---|---|
| top-level `clocks`, `generated_clocks`, `io_delays`, `false_paths` | nested under `timing:` | `TIM_ALIAS001` |
