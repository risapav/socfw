Pretože RTL emitter aktuálne pri inštancii generuje iba:

```systemverilog
blink_test blink_01 (
```

a vôbec neemituje parameter override blok:

```systemverilog
#(
  .CLK_FREQ(100000000)
)
```

Čiže `params:` sa síce pravdepodobne načítajú z `project.yaml`, ale **neprenášajú sa do RTL IR / emittera**.

Správny výstup má byť:

```systemverilog
blink_test #(
  .CLK_FREQ(100000000)
) blink_01 (
  .clk_i(clkpll_c0),
  .leds_o(ONB_LEDS),
  .rst_ni(reset_n)
);
```

Pre tvoje tri inštancie:

```systemverilog
blink_test #(
  .CLK_FREQ(100000000)
) blink_01 (
  .clk_i(clkpll_c0),
  .leds_o(ONB_LEDS),
  .rst_ni(reset_n)
);

blink_test #(
  .CLK_FREQ(100000000)
) blink_02 (
  .clk_i(clkpll_c0),
  .leds_o(w_blink_02_leds_o),
  .rst_ni(reset_n)
);

blink_test #(
  .CLK_FREQ(50000000)
) blink_03 (
  .clk_i(SYS_CLK),
  .leds_o(PMOD_J11_LED),
  .rst_ni(reset_n)
);
```

## Commit 277 — RTL parameter overrides

```text
rtl: emit module parameter overrides from project params
```

### 1. Rozšír RTL IR

V `socfw/ir/rtl.py`:

```python
@dataclass(frozen=True)
class RtlParameter:
    name: str
    value: object
```

A `RtlInstance`:

```python
@dataclass(frozen=True)
class RtlInstance:
    module: str
    instance: str
    parameters: tuple[RtlParameter, ...] = ()
    connections: tuple[RtlConnection, ...] = ()
```

### 2. Builder musí preniesť `mod.params`

V `rtl_ir_builder.py` pri vytváraní inštancie:

```python
parameters=tuple(
    RtlParameter(name=k, value=v)
    for k, v in sorted((mod.params or {}).items())
),
```

Teda:

```python
top.instances.append(
    RtlInstance(
        module=ip.module,
        instance=mod.instance,
        parameters=tuple(
            RtlParameter(name=k, value=v)
            for k, v in sorted((mod.params or {}).items())
        ),
        connections=self._connections_from_declared_ports(ip, explicit),
    )
)
```

### 3. Emitter musí emitovať `#(...)`

V `rtl_emitter.py`:

```python
def _format_param_value(self, value) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(value)
    if isinstance(value, str):
        if value.startswith(("'", '"')):
            return value
        if value.isidentifier():
            return value
        return f'"{value}"'
    return str(value)
```

A pri inštancii:

```python
if inst.parameters:
    lines.append(f"  {inst.module} #(")
    params = list(inst.parameters)
    for idx, p in enumerate(params):
        comma = "," if idx < len(params) - 1 else ""
        lines.append(f"    .{p.name}({self._format_param_value(p.value)}){comma}")
    lines.append(f"  ) {inst.instance} (")
else:
    lines.append(f"  {inst.module} {inst.instance} (")
```

### 4. Test

```python
def test_rtl_emitter_writes_parameter_overrides(tmp_path):
    top = RtlTop(
        module_name="soc_top",
        instances=[
            RtlInstance(
                module="blink_test",
                instance="blink0",
                parameters=(RtlParameter("CLK_FREQ", 50000000),),
                connections=(RtlConnection("clk_i", "SYS_CLK"),),
            )
        ],
    )

    RtlEmitter().emit_top(str(tmp_path), top)
    text = (tmp_path / "rtl" / "soc_top.sv").read_text()

    assert "blink_test #(" in text
    assert ".CLK_FREQ(50000000)" in text
    assert ") blink0 (" in text
```

## Ešte jedna vec: `adapt: replicate` ti teraz robí sign-extend

Tvoj výstup:

```systemverilog
assign PMOD_J10_LED8 = { {2{ w_blink_02_leds_o[5] } }, w_blink_02_leds_o };
```

To nie je “replicate” celého patternu, ale skôr **sign_extend** podľa MSB.

Pre 6 → 8 LED by si pravdepodobne chcel:

```yaml
adapt: zero_extend
```

a výstup:

```systemverilog
assign PMOD_J10_LED8 = {2'b00, w_blink_02_leds_o};
```

`replicate` dáva zmysel hlavne keď šírka delí cieľ, napr. 4 → 8:

```systemverilog
assign OUT8 = {2{in4}};
```

Pre 6 → 8 by som `replicate` nepovolil, lebo 8 nie je násobok 6. Mala by vzniknúť validačná chyba:

```text
BIND007 replicate requires board width to be an integer multiple of IP port width
```

Pre tvoj projekt odporúčam zmeniť:

```yaml
adapt: replicate
```

na:

```yaml
adapt: zero_extend
```
