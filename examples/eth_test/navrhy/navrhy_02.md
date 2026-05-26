Skontroloval som `eth_test.zip`, hlavne:

`project.yaml`, `timing_config.yaml`, `ip/ethernet_test.ip.yaml`, `build/rtl/soc_top.sv`, `build/hal/board.tcl`, `build/timing/soc_top.sdc`, `soc_top.qsf`, Quartus `map/fit/sta` reporty.

## Zhrnutie

Generovanie `soc_top.sv`, pinov a väzieb je formálne konzistentné. Problém nie je primárne v tom, že by `ETH_RXD/ETH_TXD` vektory neboli vygenerované. Tie sú vygenerované správne:

```tcl
set_location_assignment PIN_K22 -to ETH_RXD[0]
...
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ETH_RXD[*]

set_location_assignment PIN_V22 -to ETH_TXD[0]
...
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ETH_TXD[*]
```

Teda `ETH_TXD[*]` sa v tomto výstupe používa korektne aspoň pre `IO_STANDARD` aj v SDC cez:

```tcl
[get_ports {ETH_TXD[*]}]
```

Hlavné problémy sú inde:

1. `clk_i` v IP YAML je namapovaný na `SYS_CLK`, ale reálne sa v `ethernet_test.sv` vôbec nepoužíva.
2. Celý UDP stack beží z `eth_rx_clk_i`, teda z `ETH_RX_CLK`, nie zo `SYS_CLK`.
3. `ETH_TX_CLK`, `ETH_RX_CLK_0`, `ETH_RX_ER`, `SYS_CLK` Quartus hlási ako vstupy bez vplyvu na logiku.
4. `ETH_MDC` nemá driver, `ETH_MDIO` je stuck-at GND.
5. `ETH_RESET` je natvrdo `1'b1`, teda PHY reset sa nikdy negeneruje.
6. SDC generátor najprv aplikuje default IO delays na všetko a potom ich prepisuje override pravidlami, čo vyvoláva Quartus warningy.
7. STA výrazne neprechádza na `ETH_RX_CLK`: worst setup slack približne `-6.898 ns`.

---

## 1. `project.yaml` – clock mapovanie je zavádzajúce

V `project.yaml` máš:

```yaml
clocks:
  primary:
    domain: sys_clk
    source: board:SYS_CLK
    frequency_hz: 50000000
```

a pri module:

```yaml
modules:
  - instance: ethernet_test
    type: ethernet_test
    clocks:
      clk_i: sys_clk
```

Vygenerovaný `soc_top.sv` potom urobí:

```systemverilog
.clk_i(SYS_CLK),
```

Lenže v `rtl/ethernet_test.sv` sa `clk_i` nepoužíva vôbec. Reálna pracovná clock doména je tu:

```systemverilog
udp u_udp (
  .clk_i (eth_rx_clk_i),
  ...
);

ram u_ram (
  .clk_wr_i (eth_rx_clk_i),
  .clk_rd_i (eth_rx_clk_i),
  ...
);

always_ff @(negedge eth_rx_clk_i or negedge rst_ni)
```

Preto Quartus hlási:

```text
Warning (15610): No output dependent on input pin "SYS_CLK"
```

### Odporúčanie

Pre tento konkrétny test by som YAML nepísal tak, že primárny clock modulu je `SYS_CLK`, keď modul reálne používa `ETH_RX_CLK`.

Lepšie filozoficky:

```yaml
clocks:
  primary:
    domain: eth_rx_clk
    source: board:onboard.eth.rx_clk
    frequency_hz: 125000000

modules:
  - instance: ethernet_test
    type: ethernet_test
    clocks:
      eth_rx_clk_i: eth_rx_clk
```

Ale tvoj framework zrejme zatiaľ `clocks:` mapuje iba port deklarovaný ako `primary_input_port`. Preto by bolo lepšie upraviť IP YAML takto:

```yaml
clocking:
  primary_input_port: eth_rx_clk_i
  additional_input_ports:
    - eth_tx_clk_i
    - eth_rx_clk_0_i
  outputs:
    - eth_gtx_clk_o
```

A v `project.yaml` potom nemapovať `clk_i`, alebo `clk_i` z modulu úplne odstrániť, ak ho reálne nepotrebuješ.

---

## 2. `ethernet_test.ip.yaml` nesedí s reálnou clock architektúrou RTL

Aktuálne:

```yaml
clocking:
  primary_input_port: clk_i
  additional_input_ports: []
  outputs: []
```

Toto je pre tento IP nepravdivé. Modul síce port `clk_i` má, ale reálne sa nepoužíva. Reálne clock porty sú:

```systemverilog
input wire eth_rx_clk_i;
input wire eth_rx_clk_0_i;
input wire eth_tx_clk_i;
output logic eth_gtx_clk_o;
```

Z toho:

`eth_rx_clk_i` je skutočný clock UDP/RAM logiky.
`eth_gtx_clk_o` je clock výstup do PHY.
`eth_tx_clk_i` je síce port, ale nepoužíva sa.
`eth_rx_clk_0_i` je tiež port, ale nepoužíva sa.

### Odporúčaná úprava IP YAML

```yaml
clocking:
  primary_input_port: eth_rx_clk_i
  additional_input_ports:
    - eth_tx_clk_i
    - eth_rx_clk_0_i
  outputs:
    - eth_gtx_clk_o
```

Ešte lepšie by bolo mať v schéme možnosť definovať clock role:

```yaml
clocking:
  inputs:
    eth_rx_clk_i:
      domain: eth_rx
      frequency_hz: 125000000
      used: true
    eth_tx_clk_i:
      domain: eth_tx
      frequency_hz: 25000000
      used: false
    eth_rx_clk_0_i:
      domain: eth_rx_0
      frequency_hz: 125000000
      used: false
  outputs:
    eth_gtx_clk_o:
      derived_from: eth_rx_clk_i
```

To by umožnilo generátoru varovať, že YAML binduje nepoužité clocky.

---

## 3. `soc_top.sv` je syntakticky dobrý, ale odhaľuje problém v IP

Vygenerovaný wrapper je konzistentný:

```systemverilog
module soc_top (
  output wire ETH_GTX_CLK,
  output wire ETH_MDC,
  output wire ETH_MDIO,
  output wire ETH_RESET,
  input wire [7:0] ETH_RXD,
  input wire ETH_RX_CLK,
  input wire ETH_RX_CLK_0,
  input wire ETH_RX_DV,
  input wire ETH_RX_ER,
  output wire [7:0] ETH_TXD,
  input wire ETH_TX_CLK,
  output wire ETH_TX_EN,
  output wire ETH_TX_ER,
  input wire RESET_N,
  input wire SYS_CLK
);
```

Inštancia:

```systemverilog
ethernet_test ethernet_test (
  .clk_i(SYS_CLK),
  .eth_rx_clk_i(ETH_RX_CLK),
  .eth_tx_clk_i(ETH_TX_CLK),
  ...
);
```

Toto je správne podľa YAML. Ale `ethernet_test.sv` potom nepoužije:

```systemverilog
clk_i
eth_rx_clk_0_i
eth_rx_er_i
eth_tx_clk_i
```

Preto by som tieto porty buď odstránil z IP/YAML, alebo ich v RTL reálne použil.

---

## 4. `ETH_MDC` a `ETH_MDIO` sú problém

Quartus hlási:

```text
Warning (10034): Output port "eth_mdc_o" has no driver
Warning (12161): Node "eth_mdio_io" is stuck at GND because node is in wire loop and does not have a source
Warning (13410): Pin "ETH_MDC" is stuck at GND
Warning (13410): Pin "ETH_MDIO" is stuck at GND
```

V `ethernet_test.sv` sú porty:

```systemverilog
output logic eth_mdc_o;
inout wire eth_mdio_io;
```

ale nikde nie je:

```systemverilog
assign eth_mdc_o = ...
assign eth_mdio_io = ...
```

Ani MDIO controller nie je inštancovaný, hoci v `rtl/` máš `mdio_com.sv` a `flash_read.sv`, ktoré nie sú v `ip/ethernet_test.ip.yaml` artifacts.

### Možnosti

Pre minimálny bring-up bez MDIO:

```systemverilog
assign eth_mdc_o = 1'b0;
assign eth_mdio_io = 1'bz;
```

Lepšie:

```systemverilog
logic mdio_out;
logic mdio_oe;

assign eth_mdc_o   = mdio_mdc_w;
assign eth_mdio_io = mdio_oe ? mdio_out : 1'bz;
```

A do IP artifacts doplniť:

```yaml
artifacts:
  synthesis:
    - ../rtl/mdio_com.sv
    - ../rtl/flash_read.sv
    - ../rtl/udp.sv
    - ../rtl/ram.sv
    - ../rtl/crc.sv
    - ../rtl/ipsend.sv
    - ../rtl/ipreceive.sv
    - ../rtl/ethernet_test.sv
```

Ak MDIO teraz nechceš riešiť, aspoň ho explicitne daj do bezpečného stavu, aby Quartus nehlásil stuck wire loop.

---

## 5. `ETH_RESET` je natvrdo neaktívny

V RTL:

```systemverilog
assign eth_rst_no = 1'b1;
```

Quartus správne hlási:

```text
Pin "ETH_RESET" is stuck at VCC
```

Pre PHY reset je to slabé. Lepšie je spraviť reset extender v `ETH_RX_CLK` alebo `SYS_CLK` doméne:

```systemverilog
logic [15:0] phy_rst_cnt_q;
logic        phy_rst_done_q;

always_ff @(posedge eth_rx_clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    phy_rst_cnt_q  <= '0;
    phy_rst_done_q <= 1'b0;
  end else if (!phy_rst_done_q) begin
    phy_rst_cnt_q <= phy_rst_cnt_q + 1'b1;
    if (&phy_rst_cnt_q)
      phy_rst_done_q <= 1'b1;
  end
end

assign eth_rst_no = phy_rst_done_q;
```

Tým dostaneš reálny PHY reset namiesto konštantnej jednotky.

---

## 6. `board.tcl` je v zásade v poriadku

Vygenerovanie vektorov je dobré:

```tcl
set_location_assignment PIN_K22 -to ETH_RXD[0]
...
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to ETH_RXD[*]
```

Toto nie je chyba. Je normálne mať location assignment po bitoch a IO standard hromadne na celý vektor.

Čo chýba, sú doplnkové elektrické atribúty pre výstupy. Fitter report hlási:

```text
I/O Assignment Warnings
ETH_GTX_CLK ; Missing drive strength
ETH_MDC     ; Missing drive strength
ETH_MDIO    ; Missing drive strength
ETH_RESET   ; Missing drive strength
ETH_TXD[*]  ; Missing drive strength
ETH_TX_EN   ; Missing drive strength
ETH_TX_ER   ; Missing drive strength
```

Odporúčam do board packu/YAML pre Ethernet doplniť aspoň drive strength, prípadne slew rate:

```tcl
set_instance_assignment -name CURRENT_STRENGTH_NEW "8MA" -to ETH_TXD[*]
set_instance_assignment -name CURRENT_STRENGTH_NEW "8MA" -to ETH_TX_EN
set_instance_assignment -name CURRENT_STRENGTH_NEW "8MA" -to ETH_TX_ER
set_instance_assignment -name CURRENT_STRENGTH_NEW "8MA" -to ETH_GTX_CLK
set_instance_assignment -name SLEW_RATE 1 -to ETH_TXD[*]
```

Presnú hodnotu treba zladiť s doskou/PHY, ale framework by mal mať možnosť tieto vlastnosti popísať v board resource definícii.

---

## 7. `timing_config.yaml` / `soc_top.sdc` – override funguje, ale generátor robí špinavý SDC

V YAML máš:

```yaml
io_delays:
  auto: true
  default_clock: SYS_CLK
  default_input_max_ns: 3.0
  default_input_min_ns: 0.0
  default_output_max_ns: 3.0
  default_output_min_ns: 0.0
  overrides:
    - port: "ETH_RXD[*]"
      direction: input
      clock: ETH_RX_CLK
      max_ns: 6.0
      min_ns: 6.0
```

V SDC sa vygeneruje najprv:

```tcl
set_input_delay -clock SYS_CLK -max 3.000 [remove_from_collection [all_inputs] [get_ports {SYS_CLK RESET_N}]]
set_output_delay -clock SYS_CLK -max 3.000 [all_outputs]
```

a potom:

```tcl
set_input_delay -clock ETH_RX_CLK -max 6.000 [get_ports {ETH_RXD[*]}]
set_output_delay -clock ETH_RX_CLK -max 2.000 [get_ports {ETH_TXD[*]}]
```

Quartus potom hlási warningy typu:

```text
set_input_delay/set_output_delay has replaced one or more delays on port "ETH_RXD[7]"
```

Toto znamená, že default delay už bol aplikovaný na `ETH_RXD[*]` pod `SYS_CLK` a override ho potom prepísal pod `ETH_RX_CLK`.

### Lepší generovaný SDC

Framework by mal z default kolekcie odčítať všetky explicitné override porty.

Namiesto:

```tcl
set_input_delay -clock SYS_CLK -max 3.000 [remove_from_collection [all_inputs] [get_ports {SYS_CLK RESET_N}]]
```

generovať niečo v štýle:

```tcl
set default_inputs [remove_from_collection [all_inputs] [get_ports {SYS_CLK RESET_N ETH_RXD[*] ETH_RX_DV}]]
set_input_delay -clock SYS_CLK -max 3.000 $default_inputs
set_input_delay -clock SYS_CLK -min 0.000 $default_inputs
```

A pre outputy:

```tcl
set default_outputs [remove_from_collection [all_outputs] [get_ports {ETH_TXD[*] ETH_TX_EN ETH_TX_ER}]]
set_output_delay -clock SYS_CLK -max 3.000 $default_outputs
set_output_delay -clock SYS_CLK -min 0.000 $default_outputs
```

Tým zmiznú replace warningy.

---

## 8. `ETH_TXD[*]` v YAML

V tomto zip-e je použitý správne:

```yaml
- port: "ETH_TXD[*]"
```

a vo výstupe je tiež správne:

```tcl
[get_ports {ETH_TXD[*]}]
```

Moje odporúčanie: v YAML vždy quote-ovať wildcard/vector porty:

```yaml
port: "ETH_TXD[*]"
port: "ETH_RXD[*]"
```

Neodporúčam zapisovať to bez úvodzoviek, hlavne kvôli budúcej prenositeľnosti YAML parserov a kvôli tomu, že `[]`, `*`, `:` a podobné znaky majú v YAML špeciálne významy v určitých kontextoch.

Framework by zároveň mal validovať, že `get_ports` pattern niečo našiel. Ak nie, mal by skončiť chybou alebo aspoň jasným warningom:

```text
Timing override port pattern ETH_TXD[*] matched 0 top-level ports.
```

---

## 9. STA problém nie je len constraints – RTL má dlhé cesty

`output_files/soc_top.sta.summary` ukazuje:

```text
Setup 'ETH_RX_CLK' Slack : -6.898
Setup 'SYS_CLK'    Slack : -4.005
```

Najhoršie cesty sú v:

```text
udp:u_udp|ipsend:u_ip_send
ip_header_q -> check_buffer_q
```

Konkrétne checksum výpočet v `ipsend.sv`:

```systemverilog
check_buffer_q <= ip_header_q[0][15:0] + ip_header_q[0][31:16] +
                  ip_header_q[1][15:0] + ip_header_q[1][31:16] +
                  ip_header_q[2][15:0] + ip_header_q[2][31:16] +
                  ip_header_q[3][15:0] + ip_header_q[3][31:16] +
                  ip_header_q[4][15:0] + ip_header_q[4][31:16];
```

To je veľký adder tree v jednej hrane pri 125 MHz. Na Cyclone IV to pravdepodobne neprejde.

### Odporúčanie

Checksum rozbiť do viacerých cyklov:

```systemverilog
ST_MAKE_0: sum0 <= ip_header_q[0][15:0] + ip_header_q[0][31:16]
                + ip_header_q[1][15:0] + ip_header_q[1][31:16];

ST_MAKE_1: sum1 <= ip_header_q[2][15:0] + ip_header_q[2][31:16]
                + ip_header_q[3][15:0] + ip_header_q[3][31:16];

ST_MAKE_2: sum2 <= ip_header_q[4][15:0] + ip_header_q[4][31:16];

ST_MAKE_3: check_buffer_q <= sum0 + sum1 + sum2;

ST_MAKE_4: check_buffer_q[15:0] <= check_buffer_q[31:16] + check_buffer_q[15:0];

ST_MAKE_5: ip_header_q[2][15:0] <= ~check_buffer_q[15:0];
```

Toto je dôležitejšie než kozmetika v YAML.

---

## 10. `ipsend.sv` má podozrivé inferred latch hlášky

Quartus report ukazuje veľa:

```text
Info (10041): Inferred latch for "preamble_q[...]" at ipsend.sv(50)
```

Je zvláštne, že sa to deje v `always_ff`. Pravdepodobná príčina je použitie pamäťových polí inicializovaných iba v reset vetve a potom nie úplne jasne optimalizovaných. `preamble_q`, `mac_addr_q` a časť header konštánt by nemali byť registre zapisované v reset vetve, ale lokálne konštanty alebo funkcie.

Namiesto:

```systemverilog
logic [7:0] preamble_q [8];

always_ff @(negedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    preamble_q[0] <= 8'h55;
    ...
  end
end
```

radšej:

```systemverilog
function automatic logic [7:0] preamble_byte(input logic [2:0] idx);
  case (idx)
    3'd7: preamble_byte = 8'hD5;
    default: preamble_byte = 8'h55;
  endcase
endfunction
```

alebo:

```systemverilog
localparam logic [7:0] PREAMBLE [0:7] = '{
  8'h55, 8'h55, 8'h55, 8'h55,
  8'h55, 8'h55, 8'h55, 8'hD5
};
```

Podobne MAC/IP konštanty.

---

## 11. Generovaný testbench je príliš slabý

`build/sim/tb_soc_top.sv` generuje iba `ETH_RX_CLK`:

```systemverilog
always #(CLK_HALF_NS) ETH_RX_CLK = ~ETH_RX_CLK;
```

Ale `SYS_CLK` a `ETH_TX_CLK` ostanú konštantné:

```systemverilog
SYS_CLK = 1'b0;
ETH_TX_CLK = 1'b0;
```

Pre tento konkrétny RTL to simulačne nevadí, lebo `SYS_CLK` a `ETH_TX_CLK` sa nepoužívajú. Ale pre framework je to chyba filozofie: keď top-level obsahuje clock inputy, TB by mal generovať všetky clocky podľa timing/project definície.

Odporúčanie pre generator:

```systemverilog
always #10.000 SYS_CLK = ~SYS_CLK;      // 50 MHz
always #4.000  ETH_RX_CLK = ~ETH_RX_CLK; // 125 MHz
always #20.000 ETH_TX_CLK = ~ETH_TX_CLK; // 25 MHz, ak sa používa
```

A `ETH_RX_CLK_0` buď tiež generovať, alebo explicitne označiť ako nepoužitý/alias.

---

## Prioritný zoznam opráv

### P0 – opraviť RTL/IP realitu

1. V `ethernet_test.ip.yaml` zmeň `primary_input_port` z `clk_i` na `eth_rx_clk_i`.
2. Odstráň alebo reálne použi `clk_i`.
3. Rozhodni, či `eth_tx_clk_i`, `eth_rx_clk_0_i`, `eth_rx_er_i` sú potrebné. Ak nie, neviazať ich do top-levelu.
4. Daj `eth_mdc_o` a `eth_mdio_io` do definovaného stavu alebo zapoj MDIO controller.
5. Nahraď `assign eth_rst_no = 1'b1` reset sekvenciou pre PHY.

### P1 – opraviť timing

1. Rozbi checksum v `ipsend.sv` do viacerých cyklov.
2. Nepoužívaj `negedge eth_rx_clk_i`, ak to nie je zámer kvôli PHY. Vnútorne používaj radšej `posedge`.
3. Dopíš samostatné clock domény do timing YAML: `ETH_RX_CLK`, prípadne `ETH_TX_CLK`.
4. Výstupné TX delaye by pravdepodobne nemali byť voči `ETH_RX_CLK`, ale voči clocku, ktorým PHY vzorkuje TX rozhranie. Ak `ETH_GTX_CLK = ETH_RX_CLK`, treba to v SDC vyjadriť čistejšie ako forwarded/generated clock.

### P2 – opraviť generator

1. Pri `io_delays.auto` neaplikovať default constraints na porty, ktoré majú override.
2. Validovať wildcard port patterny typu `"ETH_TXD[*]"`.
3. V board emitteri podporiť drive strength/slew rate.
4. V TB emitteri generovať všetky deklarované clock vstupy.
5. V IP schéme rozlíšiť `clock input`, `generated/forwarded clock output`, `unused physical clock`, `data/control`.

---

## Konkrétna minimálna úprava YAML pre tento stav

Začal by som takto:

```yaml
clocks:
  primary:
    domain: eth_rx_clk
    source: board:onboard.eth.rx_clk
    frequency_hz: 125000000
  generated: []
```

a v module:

```yaml
modules:
  - instance: ethernet_test
    type: ethernet_test
    clocks:
      eth_rx_clk_i: eth_rx_clk
```

a v `ip/ethernet_test.ip.yaml`:

```yaml
clocking:
  primary_input_port: eth_rx_clk_i
  additional_input_ports:
    - eth_tx_clk_i
    - eth_rx_clk_0_i
  outputs:
    - eth_gtx_clk_o
```

Ak framework zatiaľ nevie mapovať clock port iný než `primary_input_port`, toto je zároveň dobrý test, ktorý by mal odhaliť, či clocking model v socfw potrebuje rozšíriť.

## Verdikt

`examples/eth_test` je dobrý testovací prípad pre board binding a vektorové piny, ale zatiaľ nie je dobrý referenčný príklad pre clocking/timing filozofiu frameworku. Najväčší nesúlad je, že YAML tvrdí „modul beží zo `SYS_CLK`“, ale RTL v skutočnosti beží z `ETH_RX_CLK`. To potom spôsobí zavádzajúci top, slabý TB, čudné STA členenie a warningy o nepoužitom `SYS_CLK`.

Najprv by som opravil IP YAML clock model a základné RTL warnings (`MDC/MDIO/reset/unused ports`), až potom by som riešil jemné vylepšenia SDC generátora.
