Prešiel som simulačnú časť `xfcp_test_03`. Jej dobrá filozofia je:

```text
sim/
  Makefile
  unit/
    tb_*.sv
  integration/
    tb_*.sv
  logs/
```

a ciele:

```bash
make -C sim unit
make -C sim integration
make -C sim regression
make -C sim report
make -C sim clean
```

Pre `eth_test` som pripravil návrh rovnakého štýlu ako ZIP:

[Stiahnuť návrh sim adresára pre eth_test](sandbox:/mnt/data/eth_test_sim_proposal.zip)

Obsahuje:

```text
Makefile.patch
sim/
  .gitignore
  Makefile
  unit/
    tb_crc_smoke.sv
    tb_ram_latency.sv
    tb_ipreceive_udp_frame.sv
    tb_ipsend_static_packet.sv
  integration/
    tb_udp_rx_path.sv
    tb_ethernet_test_top_smoke.sv
```

## Navrhovaná štruktúra pre `examples/eth_test`

```text
examples/eth_test/
  Makefile
  project.yaml
  timing_config.yaml
  ip/
  rtl/
  sim/
    Makefile
    .gitignore
    unit/
      tb_crc_smoke.sv
      tb_ram_latency.sv
      tb_ipreceive_udp_frame.sv
      tb_ipsend_static_packet.sv
    integration/
      tb_udp_rx_path.sv
      tb_ethernet_test_top_smoke.sv
    logs/
```

## Root `Makefile` doplnok

Do hlavného `examples/eth_test/Makefile` by som doplnil:

```makefile
.PHONY: sim sim-unit sim-integration sim-regression sim-report sim-clean

sim:
	$(MAKE) -C sim regression

sim-unit:
	$(MAKE) -C sim unit

sim-integration:
	$(MAKE) -C sim integration

sim-regression:
	$(MAKE) -C sim regression

sim-report:
	$(MAKE) -C sim report

sim-clean:
	$(MAKE) -C sim clean
```

Tým budeš môcť volať:

```bash
make sim
make sim-unit
make sim-integration
make sim-report
```

rovnako pohodlne ako v `xfcp_test_03`.

## `sim/Makefile`

Hlavný návrh:

```makefile
SHELL      := bash
.SHELLFLAGS := -o pipefail -c

RTL_ETH ?= ../rtl
LOGDIR  ?= logs

VLIB ?= vlib
VMAP ?= vmap
VLOG ?= vlog -sv -suppress 2892
VSIM ?= vsim -c -do "run -all; quit -f"

ETH_COMMON = \
	$(RTL_ETH)/crc.sv \
	$(RTL_ETH)/ram.sv \
	$(RTL_ETH)/ipreceive.sv \
	$(RTL_ETH)/ipsend.sv \
	$(RTL_ETH)/udp.sv

ETH_TOP = \
	$(ETH_COMMON) \
	$(RTL_ETH)/ethernet_test.sv

UNIT_TESTS = \
	tb_crc_smoke \
	tb_ram_latency \
	tb_ipreceive_udp_frame \
	tb_ipsend_static_packet

INTEGRATION_TESTS = \
	tb_udp_rx_path \
	tb_ethernet_test_top_smoke

.PHONY: all unit integration regression report clean work $(UNIT_TESTS) $(INTEGRATION_TESTS)

all: unit integration

unit: $(UNIT_TESTS)

integration: $(INTEGRATION_TESTS)

$(LOGDIR):
	mkdir -p $(LOGDIR)

work:
	@if [ ! -d work ]; then $(VLIB) work; fi
	@$(VMAP) work work >/dev/null

regression: clean all
	@if grep -Rql "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log 2>/dev/null; then \
		echo "======================================"; \
		echo " ETH_TEST REGRESSION FAILED"; \
		echo "======================================"; \
		grep -RHn "FAIL\|\*\* Fatal:" $(LOGDIR)/tb_*.log || true; \
		exit 1; \
	else \
		echo "======================================"; \
		echo " ETH_TEST REGRESSION PASSED"; \
		echo "======================================"; \
	fi

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log
```

A potom jednotlivé ciele:

```makefile
tb_crc_smoke: work $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv unit/tb_crc_smoke.sv
	$(VSIM) tb_crc_smoke | tee $(LOGDIR)/tb_crc_smoke.log

tb_ram_latency: work $(LOGDIR)
	$(VLOG) $(RTL_ETH)/ram.sv unit/tb_ram_latency.sv
	$(VSIM) tb_ram_latency | tee $(LOGDIR)/tb_ram_latency.log

tb_ipreceive_udp_frame: work $(LOGDIR)
	$(VLOG) $(RTL_ETH)/ipreceive.sv unit/tb_ipreceive_udp_frame.sv
	$(VSIM) tb_ipreceive_udp_frame | tee $(LOGDIR)/tb_ipreceive_udp_frame.log

tb_ipsend_static_packet: work $(LOGDIR)
	$(VLOG) $(RTL_ETH)/crc.sv $(RTL_ETH)/ipsend.sv unit/tb_ipsend_static_packet.sv
	$(VSIM) tb_ipsend_static_packet | tee $(LOGDIR)/tb_ipsend_static_packet.log

tb_udp_rx_path: work $(LOGDIR)
	$(VLOG) $(ETH_COMMON) integration/tb_udp_rx_path.sv
	$(VSIM) tb_udp_rx_path | tee $(LOGDIR)/tb_udp_rx_path.log

tb_ethernet_test_top_smoke: work $(LOGDIR)
	$(VLOG) $(ETH_TOP) integration/tb_ethernet_test_top_smoke.sv
	$(VSIM) tb_ethernet_test_top_smoke | tee $(LOGDIR)/tb_ethernet_test_top_smoke.log

clean:
	rm -rf work transcript *.wlf *.log $(LOGDIR)
```

## Navrhnuté testy

### 1. `tb_crc_smoke.sv`

Účel: rýchly sanity test `crc.sv`.

Kontroluje:

```text
reset -> crc_o == 32'hFFFF_FFFF
en_i = 0 -> CRC drží hodnotu
en_i = 1 -> CRC sa zmení
```

Toto nie je ešte plný referenčný Ethernet CRC test, ale je to dobrý prvý smoke test.

Neskôr by som doplnil presný test s referenčným CRC pre Ethernet frame, ideálne s golden hodnotou vypočítanou mimo RTL.

---

### 2. `tb_ram_latency.sv`

Účel: overiť, že aktuálny `ram.sv` má očakávanú 2-taktovú read latenciu.

Kontroluje:

```text
write addr 7 = 32'h11223344
read addr 7
po 2 clk očakáva data_o == 32'h11223344
```

Toto je dôležité, lebo `ipsend.sv` číta RAM počas vysielania payloadu a jeho FSM musí byť s latenciou RAM zosúladený.

---

### 3. `tb_ipreceive_udp_frame.sv`

Účel: unit test RX parsera `ipreceive.sv`.

Testbench pošle minimálny Ethernet/IPv4/UDP rámec:

```text
Preamble:       55 55 55 55 55 55 55 D5
Dst MAC:        00 0A 35 01 FE C0
Src MAC:        DE AD BE EF 12 34
EtherType:      08 00
IPv4 total len: 00 20
UDP len:        00 0C
Payload:        "TEST"
```

Kontroluje:

```text
data_receive_o == 1
data_o == 32'h54455354
rx_total_length_o == 16'h0020
rx_data_length_o == 16'h000C
board_mac_o == 48'h000A3501FEC0
pc_mac_o == 48'hDEADBEEF1234
```

Tento test je veľmi užitočný, lebo izoluje RX časť bez TX FSM, CRC a RAM.

---

### 4. `tb_ipsend_static_packet.sv`

Účel: unit test TX FSM `ipsend.sv`.

Problém je, že `ipsend.sv` má veľmi dlhý interný časovač:

```systemverilog
if (time_counter_q == 32'h04000000)
```

To je v simulácii nepraktické. Preto testbench použije hierarchický `force`:

```systemverilog
force dut.time_counter_q = 32'h0400_0000;
@(negedge clk);
release dut.time_counter_q;
```

Potom kontroluje aspoň začiatok vysielania:

```text
tx_en_o == 1
preamble: 55 55 55 55 55 55 55 D5
tx_er_o == 0
```

Toto odhalí, či sa TX FSM vôbec rozbehne a či generuje správnu preambulu.

---

### 5. `tb_udp_rx_path.sv`

Účel: integračný test `udp.sv`, hlavne RX vetvy.

Použije rovnaký UDP rámec ako `tb_ipreceive_udp_frame.sv`, ale ide cez celý `udp` modul.

Kontroluje:

```text
data_receive_o == 1
ram_wr_data_o == 32'h54455354
rx_total_length_o == 16'h0020
rx_data_length_o == 16'h000C
```

Tento test potvrdí, že top `udp.sv` správne prepája `ipreceive`.

---

### 6. `tb_ethernet_test_top_smoke.sv`

Účel: smoke test celého `ethernet_test.sv`.

Kontroluje:

```text
eth_rst_no == 1
eth_gtx_clk_o sleduje eth_rx_clk_i
```

Zároveň vypíše varovania pre známe slabiny aktuálneho RTL:

```text
WARN: eth_mdc_o is unknown/undriven
WARN: eth_mdio_io is not high-Z
```

Tieto veci som zámerne nedal ako `FAIL`, lebo aktuálny RTL ešte MDIO nerieši. Ale test ich viditeľne označí v logu.

## Čo by som zatiaľ netestoval ako PASS/FAIL

Zatiaľ by som nerobil ostrý end-to-end test:

```text
RX UDP frame -> RAM write -> TX echo frame -> CRC check
```

Dôvod: aktuálny `ethernet_test.sv` a `ipsend.sv` majú viaceré architektonické neistoty:

1. `ipsend.sv` vysiela periodicky cez veľký interný timer, nie explicitne po RX evente.
2. RAM má 2-taktovú latenciu, ale TX FSM vyzerá, že ju nemusí korektne rešpektovať.
3. RX beží na `posedge clk_i`, TX FSM v `ipsend.sv` beží na `negedge clk_i`.
4. `ethernet_test.sv` používa `negedge eth_rx_clk_i` na inicializáciu RAM.
5. MDIO/MDC a PHY reset sú zatiaľ neúplné.

Preto je lepšie najprv mať tieto menšie testy. Až keď budú stabilné, pridať plný loopback/echo test.

## Odporúčané poradie zapracovania

1. Skopírovať `sim/` z návrhu do `examples/eth_test/sim`.
2. Do root `Makefile` pridať obsah z `Makefile.patch`.
3. Spustiť:

```bash
cd examples/eth_test
make sim-unit
```

4. Potom:

```bash
make sim-integration
```

5. Nakoniec:

```bash
make sim-report
```

V tomto prostredí som ModelSim/Questa nemal k dispozícii, takže som testy neprerunoval cez `vlog/vsim`. Návrh je pripravený podľa štýlu `xfcp_test_03` a je priamo použiteľný ako východisková simulačná sada pre `eth_test`.
