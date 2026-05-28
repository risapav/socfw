# Packs and Catalogs

## What is a Pack?

A pack is a directory with a standard structure that can contain boards, IP descriptors, CPU descriptors, vendor artifacts, RTL, and examples. Packs allow sharing definitions between projects without copy-paste.

## Recommended Pack Structure

```text
pack_root/
  pack.yaml
  boards/
    <board_id>/
      board.yaml
  ip/
    <ip_name>/
      <ip_name>.ip.yaml
      rtl/
        <module>.sv
  cpu/
    <cpu_name>/
      <cpu_name>.cpu.yaml
      rtl/
        <wrapper>.sv
  vendor/
    intel/
      pll/
      sdram/
  examples/
    <example_name>/
```

## Pack Manifest (pack.yaml)

```yaml
version: 1
kind: pack
name: my-pack
title: My Pack
provides:
  - boards
  - ip
  - cpu
```

## Resolution Precedence

For board, IP, and CPU resolution the search order is:

1. Explicit file path in project (`project.board_file`)
2. Explicit local registry dirs (`registries.ip`, `registries.cpu`)
3. Project pack roots (`registries.packs`) — first match wins
4. Built-in packs (bundled with socfw at `packs/builtin`)

## Duplicate Policy

When multiple packs provide a resource with the same name, the first match (by precedence order) wins. A warning is emitted for duplicate names at the catalog level.

## Relative Artifact Path Normalization

### Loader phase (ip_loader.py)

IP and CPU descriptors list artifact paths relative to the descriptor file. The loaders
resolve these to absolute paths at load time so that consumers never need to know the
descriptor's location:

```python
# ip_loader.py
synthesis=tuple(str((base_dir / p).resolve()) for p in doc.artifacts.synthesis)
```

A descriptor at `examples/eth_test_02/ip/foo.ip.yaml` listing `../../../rtl/axi/axi_pkg.sv`
becomes `/abs/path/to/socfw/rtl/axi/axi_pkg.sv` in memory.

### Emitter phase (files_tcl_emitter.py)

When generating `build/hal/files.tcl`, all paths are re-expressed relative to the project
directory using `os.path.relpath`. This means:

- Files **inside** the project directory emit short relative paths: `rtl/eth/crc.sv`
- Files **outside** the project directory (shared framework RTL, packs) emit `../..`-prefixed
  paths: `../../rtl/axi/axi_pkg.sv`

```python
def _norm(p: str) -> str:
    return os.path.relpath(Path(p).resolve(), base)   # base = project_dir
```

Quartus resolves all `set_global_assignment` paths relative to the `.qpf` project file,
which lives in the project directory — so `../../rtl/axi/axi_pkg.sv` resolves correctly
regardless of where Quartus or the shell is invoked from.

**Important:** `Path.relative_to()` only works when the target is under the base directory
and raises `ValueError` otherwise. `os.path.relpath` handles cross-directory traversal
and always returns a valid relative path.

## Built-in vs Project-local Packs

- **Built-in** (`packs/builtin`): Shipped with the framework. Provides reference boards, common IP, and CPU descriptors.
- **Project-local**: Listed under `registries.packs` in `project.yaml`. Take precedence over built-in packs and can override any definition.

## Project Configuration Example

```yaml
registries:
  packs:
    - ./packs           # project-local pack
    - ~/shared-socfw-packs  # user-global pack
  ip:
    - ip                # explicit local IP dir (legacy, still supported)
```
