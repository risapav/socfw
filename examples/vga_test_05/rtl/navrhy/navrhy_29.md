Áno — tento refaktor ide správnym smerom. Najmä `CHANGELOG.md` už veľmi dobre zachytáva **problém → opravu → verifikáciu** pre HDMI data-island/audio bug.

## Čo je dobré

V `CHANGELOG.md` je správne zdokumentované, že `terc4_encoder` bol zafixovaný ako 2-cyklový pipeline zarovnaný s video/control encodermi, a že scheduler používa lookahead `packet_pop_o` pri výstupe zo `ST_DATA_GUARD_LEAD`, aby sa odstránil bug `symbol-0 duplicated / symbol-31 lost`. Toto je presne typ poznámky, ktorú sa oplatí uchovať, lebo vysvetľuje nielen čo sa zmenilo, ale aj prečo.

Veľmi dobré je aj to, že changelog už fixuje verifikačné body: `tb_terc4_encoder`, aktualizovaný `tb_hdmi_period_scheduler`, a `tb_hdmi_tx_core_32x10` s `period_d2`, `di_ch*_d3` a `terc4_ref()` na cyklicky presnú kontrolu payload obsahu.

Týmto si konečne pokryl medzeru, ktorú sme riešili predtým:

```text
DATA_PAYLOAD môže mať správnu dĺžku,
ale zlý obsah na ch*_o.
```

Podľa changelogu je teraz už overované aj:

```text
ch*_o počas DATA_PAYLOAD = TERC4(payload symbolov) cycle-accurately
```

To je veľký posun.

---

## Makefile — stav

Aktuálny `Makefile` už obsahuje nový target:

```makefile
terc4_encoder:
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/terc4_encoder.sv \
	        tb_terc4_encoder.sv
	$(VSIM) tb_terc4_encoder
```

a je zaradený do `all`:

```makefile
all: bch_ecc data_island scheduler acr_packet audio_sample_pkt tx_core_32x10 terc4_encoder
```

To je správne. Tým je regresia 2-cyklového TERC4 už súčasťou hlavnej testovacej sady.

---

## Čo by som ešte upravil v Makefile

### 1. Použiť `?=` namiesto `:=`

Teraz máš:

```makefile
RTL  := ../rtl/hdmi
VRTL := ../rtl/video
```

Lepšie:

```makefile
RTL  ?= ../rtl/hdmi
VRTL ?= ../rtl/video
```

Potom vieš spustiť testy aj z inej adresárovej štruktúry:

```bash
make RTL=/path/to/rtl/hdmi VRTL=/path/to/rtl/video all
```

---

### 2. Pridať `LOGDIR`

Teraz sa používa globálny `transcript`, ktorý ModelSim/Questa prepisuje pri každom teste. Pre fixovanie výsledkov je lepšie mať samostatné logy:

```makefile
LOGDIR ?= logs

$(LOGDIR):
	mkdir -p $(LOGDIR)
```

A napríklad:

```makefile
terc4_encoder: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/terc4_encoder.sv \
	        tb_terc4_encoder.sv
	$(VSIM) tb_terc4_encoder | tee $(LOGDIR)/tb_terc4_encoder.log
```

---

### 3. Pridať `regression` alebo `report`

Teraz `all` spustí testy, ale nevytvorí jeden hlavný report. Doplnil by som:

```makefile
.PHONY: regression report

regression: all
	@echo "======================================"
	@echo " HDMI SIM REGRESSION PASSED"
	@echo "======================================"

report: clean
	@mkdir -p $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log
```

Potom máš jeden príkaz:

```bash
make report
```

a výsledok zostane v:

```text
sim/logs/regression_full.log
```

---

### 4. `terc4_encoder` dať pred `tx_core_32x10`

Teraz je poradie:

```makefile
all: bch_ecc data_island scheduler acr_packet audio_sample_pkt tx_core_32x10 terc4_encoder
```

Logicky by som dal `terc4_encoder` pred core integration test:

```makefile
all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt tx_core_32x10
```

Dôvod: najprv overíš unit test encoderu, až potom core test, ktorý ho používa.

---

## Odporúčaná upravená kostra Makefile

```makefile
RTL  ?= ../rtl/hdmi
VRTL ?= ../rtl/video

LOGDIR ?= logs

VLOG := vlog -sv -suppress 2892
VSIM := vsim -c -do "run -all; quit"

.PHONY: all regression report clean \
        bch_ecc terc4_encoder data_island scheduler \
        acr_packet audio_sample_pkt tx_core_32x10

all: bch_ecc terc4_encoder data_island scheduler acr_packet audio_sample_pkt tx_core_32x10

$(LOGDIR):
	mkdir -p $(LOGDIR)

regression: all
	@echo "======================================"
	@echo " HDMI SIM REGRESSION PASSED"
	@echo "======================================"

report: clean $(LOGDIR)
	$(MAKE) regression 2>&1 | tee $(LOGDIR)/regression_full.log

bch_ecc: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_bch_ecc.sv tb_hdmi_bch_ecc.sv
	$(VSIM) tb_hdmi_bch_ecc | tee $(LOGDIR)/tb_hdmi_bch_ecc.log

terc4_encoder: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/terc4_encoder.sv \
	        tb_terc4_encoder.sv
	$(VSIM) tb_terc4_encoder | tee $(LOGDIR)/tb_terc4_encoder.log

data_island: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        tb_data_island_formatter.sv
	$(VSIM) tb_data_island_formatter | tee $(LOGDIR)/tb_data_island_formatter.log

scheduler: $(LOGDIR)
	$(VLOG) $(RTL)/hdmi_pkg.sv \
	        $(RTL)/hdmi_period_scheduler.sv \
	        tb_hdmi_period_scheduler.sv
	$(VSIM) tb_hdmi_period_scheduler | tee $(LOGDIR)/tb_hdmi_period_scheduler.log

acr_packet: $(LOGDIR)
	$(VLOG) $(RTL)/acr_packet_builder.sv tb_acr_packet_builder.sv
	$(VSIM) tb_acr_packet_builder | tee $(LOGDIR)/tb_acr_packet_builder.log

audio_sample_pkt: $(LOGDIR)
	$(VLOG) $(RTL)/audio_sample_packet_builder.sv tb_audio_sample_packet_builder.sv
	$(VSIM) tb_audio_sample_packet_builder | tee $(LOGDIR)/tb_audio_sample_packet_builder.log

tx_core_32x10: $(LOGDIR)
	$(VLOG) \
	        $(RTL)/hdmi_pkg.sv \
	        $(VRTL)/video_pkg.sv \
	        $(VRTL)/video_timing_generator.sv \
	        $(RTL)/tmds_video_encoder.sv \
	        $(RTL)/tmds_control_encoder.sv \
	        $(RTL)/terc4_encoder.sv \
	        $(RTL)/hdmi_period_scheduler.sv \
	        $(RTL)/hdmi_channel_mux.sv \
	        $(RTL)/infoframe_builder.sv \
	        $(RTL)/hdmi_bch_ecc.sv \
	        $(RTL)/data_island_formatter.sv \
	        $(RTL)/gcp_packet_builder.sv \
	        $(RTL)/acr_packet_builder.sv \
	        $(RTL)/audio_sample_packet_builder.sv \
	        $(RTL)/hdmi_audio_test_src.sv \
	        $(RTL)/hdmi_packet_arbiter.sv \
	        $(RTL)/hdmi_tx_core.sv \
	        tb_hdmi_tx_core_32x10.sv
	$(VSIM) tb_hdmi_tx_core_32x10 | tee $(LOGDIR)/tb_hdmi_tx_core_32x10.log

clean:
	rm -rf work transcript *.log logs
```

---

## CHANGELOG.md — odporúčané drobné úpravy

Aktuálna sekcia `vga_test_05 HDMI fixes` je dobrá. Doplnil by som tam ešte dve veci.

### 1. Explicitne uviesť pôvodný symptóm

Napríklad:

```markdown
### Symptom
- Hardware monitor displayed video for:
  - `ENABLE_AUDIO=0, ENABLE_DATA_ISLAND=0`
  - `ENABLE_AUDIO=0, ENABLE_DATA_ISLAND=1`
  - `ENABLE_AUDIO=1, ENABLE_DATA_ISLAND=0`
- Monitor went to sleep for:
  - `ENABLE_AUDIO=1, ENABLE_DATA_ISLAND=1`
```

Toto je dôležité, lebo o pol roka bude jasné, prečo sa tieto opravy robili.

### 2. Explicitne pridať „remaining validation“

Napríklad:

```markdown
### Remaining validation
- Re-run hardware matrix after scheduler/formatter/core fixes.
- Test isolated packet modes:
  - ACR only
  - Audio InfoFrame only
  - Audio Sample only
  - ACR + Audio InfoFrame
  - Full audio
```

Lebo zatiaľ changelog výborne dokumentuje sim fixy, ale ešte nehovorí, či už prešiel aj reálny monitor.

---

## Najbližší praktický krok

Teraz by som spravil toto poradie:

```text
1. Spusti make all / make report.
2. Ulož logs/regression_full.log.
3. Ak všetky testy prejdu, commitni Makefile + CHANGELOG.md + testbench zmeny.
4. Potom sprav HW test maticu:
   - DATA=0 AUDIO=0
   - DATA=1 AUDIO=0
   - DATA=1 AUDIO=1 ACR only
   - DATA=1 AUDIO=1 AudioIF only
   - DATA=1 AUDIO=1 Sample only
   - DATA=1 AUDIO=1 full audio
5. Výsledky dopíš do CHANGELOG.md alebo docs/TEST_MATRIX.md.
```

---

## Verdikt

Tento refaktor už dobre fixuje znalostnú stopu projektu:

```text
TERC4 latency fix je zdokumentovaný.
Data-island packet_pop korekcia je zdokumentovaná.
Core-level payload content verification je zdokumentovaná.
CI-friendly failure správanie je zdokumentované.
```

Makefile ešte potrebuje hlavne logovanie a report target, ale funkčne už obsahuje nový `terc4_encoder` regression test.
