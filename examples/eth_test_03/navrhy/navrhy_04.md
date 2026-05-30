Dá sa to zapojiť veľmi dobre — **Questa nechaj ako referenčný/kompatibilný simulátor**, ale **Verilator používaj na rýchle lintovanie, rýchle regresie a dlhé packet-level simulácie**. Pre tvoje Ethernet projekty je to ideálne: Questa na plnú SystemVerilog simuláciu, Verilator na rýchly vývoj modulov ako `crc32_eth`, `gmii_tx_mac`, `gmii_rx_mac`, parsery a full-path packet testy.

## 1. Rozumné rozdelenie úloh

### Questa / ModelSim používaj na

```text
- plnú SystemVerilog kompatibilitu
- existujúce SV testbenche
- waveform ladenie vo GUI
- inicializačné X/Z správanie
- tristate/inout MDIO testy
- porovnanie s Quartus/Intel flow
```

### Verilator používaj na

```text
- veľmi rýchly lint
- kompiláciu RTL do C++
- dlhé packet simulácie
- regresné testy v CI/GitHub Actions
- presné byte-by-byte porovnanie Ethernet rámcov
- rýchle testovanie CRC, parserov, FSM a stream handshakov
```

Prakticky: **každý modul najprv prebehne cez Verilator lint + rýchly C++ test**, a ak prejde, až potom ho púšťaš v Questa s waveformami.

---

# 2. Navrhovaná štruktúra `sim/`

Pre `eth_test_03` by som spravil:

```text
sim/
  Makefile

  questa/
    tb_crc32_eth.sv
    tb_gmii_tx_mac_min_frame.sv
    tb_gmii_rx_mac_with_preamble.sv
    tb_udp_echo_full_path.sv

  verilator/
    cpp/
      tb_crc32_eth.cpp
      tb_gmii_tx_mac.cpp
      tb_gmii_rx_mac.cpp
      tb_udp_echo_full_path.cpp

    sv/
      verilator_top_crc32_eth.sv
      verilator_top_gmii_tx_mac.sv
      verilator_top_gmii_rx_mac.sv

    obj_dir/
    logs/
```

Alebo jednoduchšie:

```text
sim/
  unit/
    tb_*.sv              # Questa testbenche

  verilator/
    tb_*.cpp             # C++ testy
    wrapper_*.sv         # malé SV wrappery pre Verilator

  logs/
```

---

# 3. Makefile ciele

Do `sim/Makefile` by som pridal samostatné ciele:

```makefile
.PHONY: lint verilator verilator-unit questa-unit regression clean

RTL_ROOT ?= ../rtl/eth
LOGDIR   ?= logs

VERILATOR ?= verilator
VLOG      ?= vlog -sv
VSIM      ?= vsim -c -do "run -all; quit -f"

COMMON_RTL = \
	$(RTL_ROOT)/eth_pkg.sv

MAC_RTL = \
	$(RTL_ROOT)/mac/crc32_eth.sv \
	$(RTL_ROOT)/l2/eth_header_builder.sv \
	$(RTL_ROOT)/mac/gmii_tx_mac.sv \
	$(RTL_ROOT)/mac/gmii_rx_mac.sv

L2_RTL = \
	$(RTL_ROOT)/l2/eth_header_parser.sv

L3_RTL = \
	$(RTL_ROOT)/l3/ipv4_checksum.sv \
	$(RTL_ROOT)/l3/ipv4_header_parser.sv

L4_RTL = \
	$(RTL_ROOT)/l4/udp_echo_app.sv

$(LOGDIR):
	mkdir -p $(LOGDIR)

lint: $(LOGDIR)
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--timing \
		$(COMMON_RTL) $(MAC_RTL) $(L2_RTL) $(L3_RTL) $(L4_RTL) \
		2>&1 | tee $(LOGDIR)/verilator_lint.log

questa-unit:
	$(MAKE) tb_crc32_eth_questa
	$(MAKE) tb_gmii_tx_mac_min_frame_questa
	$(MAKE) tb_gmii_rx_mac_with_preamble_questa

verilator-unit:
	$(MAKE) tb_crc32_eth_verilator
	$(MAKE) tb_gmii_tx_mac_verilator
	$(MAKE) tb_gmii_rx_mac_verilator

regression: clean lint verilator-unit questa-unit
	@echo "PASS: mixed Questa + Verilator regression"

clean:
	rm -rf work transcript *.wlf verilator/obj_dir $(LOGDIR)
```

---

# 4. Verilator lint ako prvý filter

Toto je najväčší okamžitý prínos. Cieľ:

```bash
make -C sim lint
```

Ti rýchlo odhalí veci ako:

```text
- nepriradené signály
- šírkové mismatche
- latch warningy
- nepoužité signály
- nedosiahnuteľné vetvy
- viacnásobné drivery
- nekompatibilné SystemVerilog konštrukcie
```

Pre tvoje aktuálne moduly by lint veľmi rýchlo našiel napríklad:

```text
gmii_rx_mac:
  m_axis_tlast/frame_done_o nepriradené

ethernet_test_03_top:
  neexistujúce moduly alebo `...`

udp_echo_app:
  signály, ktoré sa nepoužívajú alebo sú nekorektne riadené
```

Odporúčam mať lint cieľ v GitHub CI ako povinný.

---

# 5. Ako písať Verilator testbench

Verilator je najlepší, keď testbench píšeš v C++ a kontroluješ bajty programovo.

Napríklad pre `crc32_eth`:

```cpp
#include "Vcrc32_eth.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static vluint64_t main_time = 0;

static void tick(Vcrc32_eth* dut) {
    dut->clk_i = 0;
    dut->eval();
    main_time++;

    dut->clk_i = 1;
    dut->eval();
    main_time++;
}

static void reset(Vcrc32_eth* dut) {
    dut->rst_ni = 0;
    dut->clear_i = 0;
    dut->en_i = 0;
    dut->data_i = 0;
    tick(dut);
    tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

static void feed_byte(Vcrc32_eth* dut, uint8_t b) {
    dut->data_i = b;
    dut->en_i = 1;
    tick(dut);
    dut->en_i = 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* dut = new Vcrc32_eth;

    reset(dut);

    const char* s = "123456789";

    dut->clear_i = 1;
    tick(dut);
    dut->clear_i = 0;

    for (int i = 0; s[i] != 0; ++i) {
        feed_byte(dut, static_cast<uint8_t>(s[i]));
    }

    uint32_t fcs = dut->fcs_o;

    if (fcs != 0xCBF43926u) {
        std::printf("FAIL: CRC got 0x%08x expected 0xCBF43926\n", fcs);
        return 1;
    }

    std::printf("PASS: crc32_eth 123456789\n");

    delete dut;
    return 0;
}
```

Cieľ v Makefile:

```makefile
tb_crc32_eth_verilator: $(LOGDIR)
	$(VERILATOR) -Wall --cc \
		$(RTL_ROOT)/mac/crc32_eth.sv \
		--exe verilator/tb_crc32_eth.cpp \
		--Mdir verilator/obj_dir_crc \
		--build
	./verilator/obj_dir_crc/Vcrc32_eth | tee $(LOGDIR)/tb_crc32_eth_verilator.log
```

---

# 6. Verilator test pre `gmii_tx_mac`

Toto je veľmi vhodné pre tvoj projekt. C++ test vie jednoducho zbierať `gmii_txd_o` vždy, keď `gmii_tx_en_o=1`.

Pseudokód:

```cpp
std::vector<uint8_t> tx_bytes;

for (int cycle = 0; cycle < 2000; cycle++) {
    drive_payload_if_ready(dut);

    tick(dut);

    if (dut->gmii_tx_en_o) {
        tx_bytes.push_back(dut->gmii_txd_o);
    }
}

compare_vector(tx_bytes, expected_frame);
```

Očakávaný frame pre HELLO:

```text
55 55 55 55 55 55 55 D5
DE AD BE EF 12 34
00 0A 35 01 FE C0
08 00
<IPv4/UDP payload alebo testovací payload>
<padding>
<FCS little-endian>
```

Verilator je tu výborný, lebo byte-by-byte porovnanie je v C++ pohodlné.

---

# 7. Kedy použiť Questa waveform

Workflow:

```text
1. Verilator lint failne:
   opravíš RTL bez GUI.

2. Verilator C++ test failne:
   vypíše index bajtu, očakávanú a reálnu hodnotu.

3. Ak je chyba nejasná:
   pustíš rovnaký test alebo zjednodušený SV test v Questa
   a otvoríš waveform.
```

Teda Questa používaj až vtedy, keď chceš vidieť:

```text
state_q
frame_cnt_q
payload_cnt_q
crc_state
fcs_cnt
m_axis_tvalid/tready/tlast
```

Nie na každé drobné spustenie.

---

# 8. VCD/FST waveform z Verilatoru

Verilator vie generovať waveformy. Pre debug bez Questa GUI môžeš použiť GTKWave.

Kompilácia:

```makefile
tb_gmii_tx_mac_verilator_trace:
	$(VERILATOR) -Wall --trace --cc \
		$(COMMON_RTL) \
		$(RTL_ROOT)/mac/crc32_eth.sv \
		$(RTL_ROOT)/l2/eth_header_builder.sv \
		$(RTL_ROOT)/mac/gmii_tx_mac.sv \
		--exe verilator/tb_gmii_tx_mac.cpp \
		--Mdir verilator/obj_dir_tx \
		--build
	./verilator/obj_dir_tx/Vgmii_tx_mac +trace
```

V C++:

```cpp
#include "verilated_vcd_c.h"

Verilated::traceEverOn(true);
VerilatedVcdC* tfp = new VerilatedVcdC;
dut->trace(tfp, 99);
tfp->open("logs/gmii_tx_mac.vcd");

// po každom eval:
tfp->dump(main_time);
```

Potom:

```bash
gtkwave logs/gmii_tx_mac.vcd
```

Toto je rýchlejšie než otvárať Questa GUI pri každom pokuse.

---

# 9. Obmedzenia Verilatoru

Treba s nimi počítať.

Verilator nie je úplná náhrada Questa. Horšie sa hodí na:

```text
- plné event-driven SV testbenche s delaymi a fork/join komplexitou
- niektoré SystemVerilog assertions podľa použitia
- tri-state/inout analógovejšie správanie
- X/Z propagáciu ako v event simulátore
- vendor primitives a PLL modely
```

Pre tvoje Ethernet bloky je však výborný na:

```text
crc32_eth
gmii_tx_mac
gmii_rx_mac
eth_header_parser
ipv4_checksum
udp_echo_app
full byte stream test
```

Pre `MDIO` by som stále radšej validoval aj v Questa, lebo `inout mdio_io` a tri-state turnaround sa lepšie pozoruje vo waveform simulátore.

---

# 10. Ako upraviť RTL, aby bol Verilator-friendly

Odporúčam tieto pravidlá:

```text
1. Nepoužívať `#delay` v RTL.
2. Nedávať `initial` do syntetizovateľných modulov, okrem test-only.
3. Mať všetky výstupy priradené v každom stave.
4. Nepoužívať implicitné nety, zachovať `default_nettype none`.
5. Vyhnúť sa `inout` vo vnútri väčšiny knižnice; MDIO držať izolovane.
6. Parametre a šírky písať explicitne.
7. Mať malé top wrappery pre Verilator.
```

Napríklad pre MDIO by som mal dve vrstvy:

```text
mdio_master_core:
  mdio_in_i
  mdio_out_o
  mdio_oe_o

mdio_pad:
  inout mdio_io
```

Verilator testuje hlavne `mdio_master_core`, Questa potom aj `mdio_pad`.

---

# 11. Wrappery pre Verilator

Pre moduly s package/import alebo zložitejšími portmi sprav jednoduchý wrapper.

Napríklad:

```systemverilog
module verilator_top_gmii_tx_mac (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic       start_i,
  input  logic [7:0] data_i,
  input  logic       valid_i,
  input  logic       last_i,
  output logic       ready_o,

  output logic [7:0] txd_o,
  output logic       tx_en_o,
  output logic       tx_er_o,
  output logic       busy_o,
  output logic       done_o
);

  gmii_tx_mac dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .tx_start_i(start_i),
    .tx_busy_o(busy_o),
    .tx_done_o(done_o),

    .tx_dst_mac_i(48'hDEADBEEF1234),
    .tx_src_mac_i(48'h000A3501FEC0),
    .tx_ethertype_i(16'h0800),
    .tx_payload_len_i(16'd33),

    .s_axis_tdata(data_i),
    .s_axis_tvalid(valid_i),
    .s_axis_tready(ready_o),
    .s_axis_tlast(last_i),

    .gmii_txd_o(txd_o),
    .gmii_tx_en_o(tx_en_o),
    .gmii_tx_er_o(tx_er_o)
  );

endmodule
```

Potom C++ test pracuje s jednoduchými portami.

---

# 12. Navrhovaný zmiešaný workflow

## Bežný vývoj modulu

```bash
make -C sim lint
make -C sim tb_crc32_eth_verilator
make -C sim tb_crc32_eth_questa
```

## Vývoj `gmii_tx_mac`

```bash
make -C sim tb_gmii_tx_mac_verilator
```

Ak failne byte mismatch:

```text
Mismatch byte 22: got 0x00 expected 0x45
```

otvoríš Questa:

```bash
make -C sim tb_gmii_tx_mac_min_frame_questa GUI=1
```

## Pred commitom

```bash
make -C sim regression
```

kde `regression` robí:

```text
Verilator lint
Verilator unit tests
Questa unit tests
Questa integration tests
```

---

# 13. GitHub Actions

Na GitHube by som spúšťal minimálne Verilator. Questa je licenčne a prakticky zložitejšia.

`.github/workflows/verilator.yml`:

```yaml
name: Verilator

on:
  push:
  pull_request:

jobs:
  verilator:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Install Verilator
        run: |
          sudo apt-get update
          sudo apt-get install -y verilator build-essential

      - name: Run lint
        run: |
          make -C examples/eth_test_03/sim lint

      - name: Run Verilator unit tests
        run: |
          make -C examples/eth_test_03/sim verilator-unit
```

Questa si nechaj lokálne alebo na vlastnom runneri.

---

# 14. Ako by som to zaviedol konkrétne v `eth_test_03`

## Fáza 1

Pridať:

```text
sim/verilator/tb_crc32_eth.cpp
sim/verilator/tb_gmii_tx_mac.cpp
sim/verilator/tb_gmii_rx_mac.cpp
```

A Makefile ciele:

```text
lint
tb_crc32_eth_verilator
tb_gmii_tx_mac_verilator
tb_gmii_rx_mac_verilator
verilator-unit
```

## Fáza 2

Pridať Questa ekvivalenty:

```text
tb_crc32_eth.sv
tb_gmii_tx_mac_min_frame.sv
tb_gmii_rx_mac_with_preamble.sv
```

## Fáza 3

Full path:

```text
tb_eth_test_03_udp_full_path.cpp
```

Vo Verilatore bude extrémne vhodné robiť celý packet scoreboard v C++.

---

## Záver

Najefektívnejší model pre teba je:

```text
Verilator:
  rýchly lint
  rýchle byte-level testy
  CI regresia
  CRC/GMII/parser/packet testy

Questa:
  referenčné SV testbenche
  waveform debug
  inout/MDIO/X/Z správanie
  finálne overenie pred Quartus buildom
```

Pre `eth_test_03` by som Verilator zapojil okamžite, najprv na `crc32_eth`, `gmii_tx_mac` a `gmii_rx_mac`. Práve tieto moduly sú základ Ethernet knižnice a Verilator ti pri nich dá najväčšie zrýchlenie ladenia.
