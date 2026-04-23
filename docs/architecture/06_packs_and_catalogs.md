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

IP and CPU descriptors list artifact paths relative to the descriptor file. The loaders resolve these to absolute paths at load time so that consumers never need to know the descriptor's location.

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
