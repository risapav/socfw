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
