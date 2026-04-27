# Project Configuration Schema v2

Canonical YAML structure for `project.yaml`. Legacy aliases are accepted with deprecation warnings.

## Top-level keys

```yaml
project:
  name: <string>          # design name
  mode: <string>          # fpga | sim | ...
  board: <string>         # board type identifier
  board_file: <string>    # path to board YAML (optional)
  debug: <bool>           # enable debug output (default: false)

registries:
  ip: [<path>, ...]       # IP search paths
  packs: [<path>, ...]    # pack search paths
  cpu: [<path>, ...]      # CPU registry paths

features:
  use: [<string>, ...]    # feature flags to enable

clocks:
  primary:
    domain: <string>      # primary clock domain name
  generated:
    - domain: <string>
      source:
        instance: <string>
        output: <string>
      frequency_hz: <int>
      reset:
        sync_from: <string>
        sync_stages: <int>
        none: <bool>

modules:
  - instance: <string>    # instance name (must be unique)
    type: <string>        # IP type (must match ip.name in a loaded descriptor)
    params:               # parameter overrides — emitted as #(.NAME(VALUE)) in RTL
      <PARAM>: <value>    # int, bool (→ 0/1), SV literal string (e.g. "4'b1010"), identifier
    clocks:
      <port>: <domain>    # or {domain: ..., no_reset: true}
    bind:
      ports:
        <port>:
          target: <string>
          top_name: <string>
          width: <int>
          adapt: <string>
    bus:
      fabric: <string>
      base: <hex>
      size: <hex>

buses:
  - name: <string>
    protocol: <string>
    addr_width: <int>
    data_width: <int>

connections:
  - from: <instance>.<port>   # source module instance and port name
    to: <instance>.<port>     # destination module instance and port name

timing:
  file: <path>            # path to timing YAML

cpu:
  instance: <string>
  type: <string>
  fabric: <string>
  reset_vector: <hex>
  params: {}

ram:
  module: <string>
  base: <hex>
  size: <hex>
  data_width: <int>
  addr_width: <int>
  latency: <int>
  init_file: <path>
  image_format: <string>

firmware:
  enabled: <bool>
  src_dir: <path>
  out_dir: <path>
  linker_script: <path>
  elf_file: <path>
  bin_file: <path>
  hex_file: <path>
  tool_prefix: <string>
  cflags: [<string>, ...]
  ldflags: [<string>, ...]

boot:
  reset_vector: <hex>
  stack_percent: <int>
```

## Deprecated aliases (v1 → v2)

| Deprecated key | Canonical key | Warning code |
|---|---|---|
| `timing.config` | `timing.file` | `PRJ_ALIAS001` |
| `paths.ip_plugins` | `registries.ip` | `PRJ_ALIAS002` |
| `board.type` | `project.board` | `PRJ_ALIAS003` |
| `board.file` | `project.board_file` | `PRJ_ALIAS004` |
| `design.name` | `project.name` | `PRJ_ALIAS005` |
| `design.mode` | `project.mode` | `PRJ_ALIAS006` |
| dict-style `modules` | list-style `modules` | `PRJ_ALIAS007` |
