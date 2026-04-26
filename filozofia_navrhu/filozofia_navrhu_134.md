Áno. Tu sú koreňové príčiny.

## 1. `RESET_N` je v top-level, ale blink ho nepoužíva

Quartus hlási:

```text
object "reset_active" assigned a value but never read
object "reset_n" assigned a value but never read
No output dependent on input pin "RESET_N"
```

To znamená: `soc_top.sv` vytvorí reset logiku, ale `blink_test` nemá reset port alebo nie je pripojený.

Máš 2 možnosti.

### Možnosť A — blink bez resetu

Pre najjednoduchší blink odstráň reset z timing configu:

```yaml
timing:
  derive_uncertainty: true

  clocks:
    - name: SYS_CLK
      source: SYS_CLK
      period_ns: 20.0

  false_paths: []
```

A framework by potom nemal emitovať `RESET_N`, `reset_active`, `reset_n`.

### Možnosť B — blink s resetom, odporúčané

Uprav RTL blink modulu na reset:

```systemverilog
module blink_test #(
  parameter integer CLK_FREQ = 50000000
)(
  input  wire       clk_i,
  input  wire       rst_ni,
  output reg  [5:0] leds_o
);

  reg [31:0] counter;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      counter <= 32'd0;
      leds_o <= 6'd0;
    end else begin
      counter <= counter + 1'b1;
      leds_o <= counter[25:20];
    end
  end

endmodule
```

A do `blink_test.ip.yaml` pridaj:

```yaml
reset:
  port: rst_ni
  active_high: false

ports:
  - name: clk_i
    direction: input
    width: 1
  - name: rst_ni
    direction: input
    width: 1
  - name: leds_o
    direction: output
    width: 6
```

Potom `soc_top.sv` má mať:

```systemverilog
.rst_ni(reset_n)
```

---

## 2. Chýba `derive_clock_uncertainty`

Máš:

```yaml
derive_uncertainty: true
```

ale SDC zjavne neemituje:

```tcl
derive_clock_uncertainty
```

Preto Quartus hlási:

```text
clock transfers have no clock uncertainty assignment
```

Do `soc_top.sdc` má pribudnúť:

```tcl
derive_clock_uncertainty
```

---

## 3. IO delays sú generované neúplne

Quartus hlási chýbajúce:

```text
min-fall
min-rise
```

To znamená, že emitter generuje len `-max`, ale nie `-min`.

Pre tvoje timing YAML by SDC mal obsahovať aj:

```tcl
set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
set_output_delay -clock SYS_CLK -min 3.000 [get_ports {ONB_LEDS[*]}]
```

Pre clock port `SYS_CLK` a async reset `RESET_N` by sa IO delay typicky nemal aplikovať ako bežný data input.

---

## 4. `all_inputs` / `all_outputs` je príliš hrubé

Ak emitter generuje:

```tcl
set_input_delay -clock SYS_CLK -max 3.000 [all_inputs]
set_output_delay -clock SYS_CLK -max 3.000 [all_outputs]
```

tak zahrnie aj `SYS_CLK` a `RESET_N`. To spôsobuje časť warningov.

Lepšie je generovať iba selected data porty a explicitne vylúčiť clock/reset:

```tcl
set_false_path -from [get_ports {RESET_N}]
```

a output delay pre LED:

```tcl
set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
set_output_delay -clock SYS_CLK -min 3.000 [get_ports {ONB_LEDS[*]}]
```

---

## 5. Warnings sa opakujú — SDC je pravdepodobne source-nuté viackrát

Keď vidíš rovnaký blok warningov viackrát, často je príčina:

* `soc_top.sdc` je v `files.tcl` ako `SDC_FILE`
* a zároveň sa ručne `source`-uje v inom TCL

Správne zvoľ **jednu cestu**.

Odporúčam v `files.tcl`:

```tcl
set_global_assignment -name SDC_FILE "../timing/soc_top.sdc"
```

a v `project.tcl` už nerobiť:

```tcl
source ../timing/soc_top.sdc
```

---

## 6. Incomplete I/O assignments

Toto:

```text
Some pins have incomplete I/O assignments
```

znamená, že `board.tcl` asi nastavuje piny, ale nie IO standard.

Pre LED má byť napr.:

```tcl
set_location_assignment E4 -to ONB_LEDS[0]
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ONB_LEDS[0]
```

To isté pre `SYS_CLK`, `RESET_N`.

---

# Odporúčané commity

## Commit 251

```text
rtl: emit reset nets only when consumed by instantiated IP
```

Ak žiadna IP nemá reset port, negenerovať:

```systemverilog
RESET_N
reset_active
reset_n
```

alebo aspoň negenerovať unused internal nets.

---

## Commit 252

```text
examples: add reset-aware blink_test variant
```

Upraviť `blink_test_01` tak, aby mal reset:

```yaml
clocks:
  clk_i: sys_clk
```

a IP descriptor:

```yaml
reset:
  port: rst_ni
  active_high: false
```

---

## Commit 253

```text
emit: add derive_clock_uncertainty to native SDC emitter
```

Ak:

```yaml
timing:
  derive_uncertainty: true
```

emitovať:

```tcl
derive_clock_uncertainty
```

---

## Commit 254

```text
emit: emit min and max IO delays and exclude clock reset ports
```

Opraviť SDC emitter:

* `-max`
* `-min`
* nepoužiť `all_inputs`
* nepoužiť delay na clock/reset
* rešpektovať `io_delays.overrides`

---

## Commit 255

```text
emit: avoid duplicate SDC inclusion in Quartus scripts
```

Pravidlo:

* buď `SDC_FILE` vo `files.tcl`
* alebo `source timing/soc_top.sdc`
* nie oboje

Odporúčam ponechať `SDC_FILE`.

---

## Commit 256

```text
emit: add IO_STANDARD assignments to board.tcl
```

Pre každý pin emitovať:

```tcl
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ...
```

---

## Commit 257

```text
golden: add Quartus-clean blink_test_01 output snapshot
```

Golden musí overiť:

* `reset_n` je použité alebo vôbec negenerované
* `derive_clock_uncertainty` existuje
* LED majú min/max output delay
* `board.tcl` má IO standardy
* `files.tcl` obsahuje SDC iba raz

---

# Najrýchlejšia ručná oprava teraz

Ak chceš okamžite znížiť warningy, sprav toto:

1. Pridaj reset do `blink_test`.
2. Pridaj `rst_ni` do IP descriptoru.
3. Do SDC ručne doplň:

```tcl
derive_clock_uncertainty

set_false_path -from [get_ports {RESET_N}]

set_output_delay -clock SYS_CLK -max 3.000 [get_ports {ONB_LEDS[*]}]
set_output_delay -clock SYS_CLK -min 3.000 [get_ports {ONB_LEDS[*]}]
```

4. Zruš duplicitné sourcovanie SDC.
5. Do `board.tcl` doplň IO standard pre piny.

Najdôležitejšie frameworkové opravy sú **253, 254, 256**.
