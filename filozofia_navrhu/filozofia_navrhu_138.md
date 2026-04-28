Tvoj návrh je dobrý ako začiatok, ale má jeden zásadný integračný problém:

```systemverilog
input wire logic [3:0] digits_i [NUM_DIGITS]
input wire logic       dots_i   [NUM_DIGITS]
```

To sú **unpacked array porty**. Pre `socfw` a jednoduchý top-level generátor je praktickejšie mať **packed vector porty**, lebo tie sa dajú ľahko bindovať, tie-offovať aj generovať v `soc_top.sv`.

## Problémy v aktuálnom `seven_seg_mux.ip.yaml`

### 1. `digits_i` a `dots_i` chýbajú v `ports`

V IP descriptore máš iba:

```yaml
ports:
  - name: clk_i
  - name: rst_ni
  - name: digit_sel_o
  - name: segment_sel_o
```

Ale RTL modul reálne má ešte:

```text
digits_i
dots_i
current_digit_o
```

Ak ich nedáš do `ports`, framework ich nebude vedieť bezpečne generovať.

### 2. `digit_sel_o` width je natvrdo 6

V RTL:

```systemverilog
output logic [NUM_DIGITS-1:0] digit_sel_o
```

Ale descriptor má:

```yaml
width: 6
```

To je OK iba ak default alebo projektový parameter `NUM_DIGITS = 6`.

Tvoj RTL default má:

```systemverilog
parameter int NUM_DIGITS = 3
```

Čiže descriptor a RTL default si odporujú.

### 3. `current_digit_o` chýba

RTL má:

```systemverilog
output logic [$clog2(NUM_DIGITS)-1:0] current_digit_o
```

Ak ho nechceš pripájať, stále ho môžeš dať do descriptoru ako output, framework ho nechá otvorený.

### 4. `input wire logic` je zbytočné

Toto:

```systemverilog
input wire logic clk_i
```

je štýlovo zvláštne. Bežnejšie:

```systemverilog
input logic clk_i
```

alebo:

```systemverilog
input wire clk_i
```

Nie je to nutne chyba, ale zjednotil by som to.

---

# Odporúčané riešenie A: ponechať pôvodný RTL, ale descriptor označiť ako “manual/top unsupported”

Toto je bezpečné, ale framework ho nebude vedieť pekne zapojiť.

```yaml
version: 2
kind: ip

ip:
  name: seven_seg_mux
  module: seven_seg_mux
  category: display

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: false
  dependency_only: true

reset:
  port: rst_ni
  active_high: false

clocking:
  primary_input_port: clk_i
  additional_input_ports: []
  outputs: []

ports:
  - name: clk_i
    direction: input
    width: 1
  - name: rst_ni
    direction: input
    width: 1
  - name: digit_sel_o
    direction: output
    width: 6
  - name: segment_sel_o
    direction: output
    width: 8
  - name: current_digit_o
    direction: output
    width: 3

artifacts:
  synthesis:
    - ../rtl/segment/seven_seg_mux.sv
  simulation: []
  metadata: []

provides:
  modules:
    - seven_seg_mux

notes:
  - "digits_i and dots_i are unpacked array ports and require manual wrapper or manual top-level wiring."
```

Toto ale nie je ideálne.

---

# Odporúčané riešenie B: pridať packed wrapper

Najlepšie je pridať nový wrapper napríklad:

```text
seven_seg_mux_packed.sv
```

Ten bude mať porty:

```systemverilog
input logic [NUM_DIGITS*4-1:0] digits_i
input logic [NUM_DIGITS-1:0]   dots_i
```

a interne ich prekonvertuje na unpacked arrays.

## `seven_seg_mux_packed.sv`

```systemverilog
`default_nettype none

module seven_seg_mux_packed #(
  parameter int CLOCK_FREQ_HZ    = 50_000_000,
  parameter int NUM_DIGITS       = 6,
  parameter int DIGIT_REFRESH_HZ = 250,
  parameter bit COMMON_ANODE     = 1'b1
)(
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic [NUM_DIGITS*4-1:0] digits_i,
  input  logic [NUM_DIGITS-1:0]   dots_i,

  output logic [NUM_DIGITS-1:0]   digit_sel_o,
  output logic [7:0]              segment_sel_o,
  output logic [$clog2(NUM_DIGITS)-1:0] current_digit_o
);

  logic [3:0] digits_unpacked [NUM_DIGITS];
  logic       dots_unpacked   [NUM_DIGITS];

  genvar i;
  generate
    for (i = 0; i < NUM_DIGITS; i = i + 1) begin : g_unpack
      assign digits_unpacked[i] = digits_i[i*4 +: 4];
      assign dots_unpacked[i]   = dots_i[i];
    end
  endgenerate

  seven_seg_mux #(
    .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ),
    .NUM_DIGITS(NUM_DIGITS),
    .DIGIT_REFRESH_HZ(DIGIT_REFRESH_HZ),
    .COMMON_ANODE(COMMON_ANODE)
  ) u_core (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .digits_i(digits_unpacked),
    .dots_i(dots_unpacked),
    .digit_sel_o(digit_sel_o),
    .segment_sel_o(segment_sel_o),
    .current_digit_o(current_digit_o)
  );

endmodule

`default_nettype wire
```

---

# Odporúčaný nový `seven_seg_mux.ip.yaml`

Pre framework by som registroval wrapper, nie pôvodný core.

```yaml
version: 2
kind: ip

ip:
  name: seven_seg_mux
  module: seven_seg_mux_packed
  category: display

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: false
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: rst_ni
  active_high: false

clocking:
  primary_input_port: clk_i
  additional_input_ports: []
  outputs: []

parameters:
  - name: CLOCK_FREQ_HZ
    type: int
    default: 50000000
  - name: NUM_DIGITS
    type: int
    default: 6
  - name: DIGIT_REFRESH_HZ
    type: int
    default: 250
  - name: COMMON_ANODE
    type: bit
    default: true

ports:
  - name: clk_i
    direction: input
    width: 1

  - name: rst_ni
    direction: input
    width: 1

  - name: digits_i
    direction: input
    width_expr: "NUM_DIGITS*4"

  - name: dots_i
    direction: input
    width_expr: "NUM_DIGITS"

  - name: digit_sel_o
    direction: output
    width_expr: "NUM_DIGITS"

  - name: segment_sel_o
    direction: output
    width: 8

  - name: current_digit_o
    direction: output
    width_expr: "$clog2(NUM_DIGITS)"

artifacts:
  synthesis:
    - ../rtl/segment/seven_seg_mux.sv
    - ../rtl/segment/seven_seg_mux_packed.sv
  simulation: []
  metadata: []

provides:
  modules:
    - seven_seg_mux
    - seven_seg_mux_packed
```

## Poznámka k `width_expr`

Ak tvoj aktuálny schema ešte nepodporuje:

```yaml
width_expr:
```

tak pre QMTech 6-digit displej použi zatiaľ konkrétne šírky:

```yaml
ports:
  - name: digits_i
    direction: input
    width: 24
  - name: dots_i
    direction: input
    width: 6
  - name: digit_sel_o
    direction: output
    width: 6
  - name: segment_sel_o
    direction: output
    width: 8
  - name: current_digit_o
    direction: output
    width: 3
```

A v projekte vždy nastav:

```yaml
params:
  NUM_DIGITS: 6
```

---

# Odporúčaný project usage

```yaml
modules:
  - instance: sevenseg0
    type: seven_seg_mux
    params:
      CLOCK_FREQ_HZ: 50000000
      NUM_DIGITS: 6
      DIGIT_REFRESH_HZ: 1000
      COMMON_ANODE: true
    clocks:
      clk_i: sys_clk
    bind:
      ports:
        digit_sel_o:
          target: board:onboard.dig
        segment_sel_o:
          target: board:onboard.seg
```

`digits_i` a `dots_i` ostanú ako inputy. Ak ich nepripojíš, framework by ich mal defaultne tie-offnúť:

```systemverilog
.digits_i(24'h0),
.dots_i(6'h0)
```

Potom bude displej ukazovať nuly.

---

# Vylepšenia frameworku ako commity

## Commit 278 — packed display wrapper

```text
rtl: add packed wrapper for seven segment mux IP
```

Pridať:

```text
rtl/segment/seven_seg_mux_packed.sv
```

Cieľ:

* odstrániť unpacked array porty z top-level integrácie
* zachovať pôvodný `seven_seg_mux` ako core

---

## Commit 279 — parameter metadata in IP descriptors

```text
ip: add parameter metadata to IP descriptors
```

Podporiť:

```yaml
parameters:
  - name: NUM_DIGITS
    type: int
    default: 6
```

Validácia:

* project `params` smie používať iba deklarované parametre
* neznámy parameter → warning/error

---

## Commit 280 — width expressions in IP ports

```text
ip: support width expressions for parameterized ports
```

Podporiť:

```yaml
width_expr: "NUM_DIGITS*4"
width_expr: "$clog2(NUM_DIGITS)"
```

Prvý krok môže byť iba jednoduchý evaluator:

* integer constants
* parameter names
* `*`, `+`, `-`
* `$clog2(...)`

---

## Commit 281 — parameter-aware width validation

```text
validate: evaluate parameterized port widths for module instances
```

Pre:

```yaml
params:
  NUM_DIGITS: 6
```

vypočíta:

```text
digits_i width = 24
digit_sel_o width = 6
current_digit_o width = 3
```

Potom vie správne porovnať s board:

```yaml
digit_sel_o -> board:onboard.dig width 6
segment_sel_o -> board:onboard.seg width 8
```

---

## Commit 282 — default tie-off for parameterized inputs

```text
rtl: tie off unbound parameterized input ports
```

Ak nie je bind:

```yaml
digits_i
dots_i
```

emitovať:

```systemverilog
.digits_i(24'h0),
.dots_i(6'h0)
```

Nie:

```systemverilog
.digits_i(1'b0)
```

---

## Commit 283 — display example

```text
examples: add seven segment static zero display example
```

Pridať:

```text
examples/seven_seg_static/project.yaml
examples/seven_seg_static/ip/seven_seg_mux.ip.yaml
examples/seven_seg_static/rtl/segment/...
```

Overiť:

* `segment_sel_o` bind na `board:onboard.seg`
* `digit_sel_o` bind na `board:onboard.dig`
* `digits_i` default 0
* `dots_i` default 0

---

# Moje odporúčanie

Nepoužívaj pôvodný `seven_seg_mux` priamo ako IP top. Použi ho ako core a pridaj `seven_seg_mux_packed` wrapper.

To je najčistejšie riešenie pre `socfw`, Quartus aj budúce automatické generovanie `soc_top.sv`.
