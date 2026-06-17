Skontroloval som aktuálny uzatvárací snapshot XFCP.

```text id="ojm1z6"
xfcp_test_13_cpu_softcore_stub(1).zip
SHA-256: 747886c5ac3d7200acc4af20cbdd78e2c7608a8272ac9ee3d5d956a03b64600c

rtl(3).zip
SHA-256: 4718c69359c86ff6dbeade2a6edc0dd5145ccd4eec4fdd7a2e451687b346b528

docs(4).zip
SHA-256: 94a2a073495bb3606afbbf870de09e01932b0960ff85577e6525074917b041db
```

## Verdikt

`xfcp_test_13_cpu_softcore_stub` je podľa priloženého statusu **uzavretý míľnik**.

```text id="yi7rtw"
Sim:        PASS, T01–T54, 0 failures
Timing:     PASS, SEED=7, CLK125 WNS +0.241 ns
HW UART:    PASS 102/102
HW UDP:     PASS 102/102
DIAG:       bez chýb
Tag:        xfcp_lib_v1_7_cpu_stub_pass
```

Toto už môžeme považovať za úspešné dokončenie XFCP pred prechodom na SDRAM podprojekt.

---

# Čo sa podarilo v test_13

Predchádzajúci problém bol správne vyriešený: staré CPUM register testy boli nekompatibilné s aktívnym CPU stubom. Teraz sú testy prepísané ako **stub-aware**.

Rozdiel je správne zdokumentovaný:

```text id="x29ymy"
test_12:
  host zapíše do RX FIFO
  dáta ostanú v RX FIFO
  host ich vie čítať cez RX_POP_DATA

test_13:
  host zapíše do RX FIFO
  CPU stub ich okamžite spotrebuje
  stub vytvorí odpoveď do TX FIFO
  host ju číta cez STREAM_READ
```

Nové stub testy pokrývajú:

```text id="4s2trc"
T50 PING -> PONG
T51 ABCD -> ERR\n
T52 PING × 4
T53 STR0 izolácia
T54 8B PING+padding -> ERR\n
```

To je presne to, čo sme chceli: prvý reálny smer **host → mailbox → CPU-side agent → mailbox → host**.

---

# Aktuálny stav knižnice

Teraz má XFCP tieto stabilné vrstvy:

```text id="55cg6z"
v0.9  STATUS + AXI-Lite
v1.1  AXI-Stream
v1.2  GET_CAPS
v1.3  GET_TARGET_INFO
v1.4  MEM / AXI-Full
v1.5  CPU0 stream mailbox
v1.6  CPUM AXI-Lite mailbox regs
v1.7  CPU-side stub PING/PONG agent
```

Toto je veľmi dobrá hranica na „freeze“.

---

# Čo je ešte potrebné upratať pred SDRAM

Nie RTL funkcia, ale dokumentácia má ešte jednu nekonzistenciu.

V `docs/xfcp/version.md` už je doplnené `v1.7 — xfcp_lib_v1_7_cpu_stub_pass`, čo je správne. Ale `docs/xfcp/README.md` stále začína:

```text id="xpmnig"
Version: 1.6
Status: xfcp_lib_v1_6_mailbox_regs_pass
```

To treba zmeniť na:

```text id="jcx3x0"
Version: 1.7
Status: xfcp_lib_v1_7_cpu_stub_pass
```

A README resource/simulation tabuľky stále opisujú primárne `xfcp_test_12_cpu_mailbox_regs`. To nie je katastrofa, ale pre uzatvárací stav by som doplnil krátku sekciu:

```text id="sj7a5f"
Latest validated example:
  xfcp_test_13_cpu_softcore_stub
  Sim T01–T54 PASS
  Timing CLK125 WNS +0.241 ns
  HW UART 102/102 PASS
  HW UDP 102/102 PASS
```

Druhá drobnosť: vo `version.md` je `v1.7` až za `v0.9`, po `v1.6/v1.5/...`. Odporúčam zoradiť verzie zostupne:

```text id="yj71eq"
v1.7
v1.6
v1.5
v1.4
...
```

Nie je to funkčný problém, ale keď to má byť knižničná dokumentácia, nech sa v nej ľahko orientuje.

---

# Stav root RTL

`rtl(3).zip` vyzerá ako použiteľný root RTL snapshot:

```text id="oqme2r"
rtl/xfcp/
  xfcp_pkg.sv
  xfcp_rx_parser.sv
  xfcp_tx_packetizer.sv
  xfcp_arbiter_2to1.sv
  xfcp_fabric_endpoint.sv
  xfcp_axi_engine.sv
  xfcp_axis_adapter.sv
  xfcp_caps_adapter.sv
  xfcp_target_info_adapter.sv
  xfcp_mem_adapter.sv
  xfcp_stream_mux.sv
  xfcp_fifo.sv
  xfcp_fifo_reg.sv
  axis_byte_register_slice.sv
  transport/*
```

A mailbox je mimo `rtl/xfcp`, čo je rozumné:

```text id="xq4wbg"
rtl/axil/axil_cpu_mailbox.sv
```

`xfcp_cpu_stub.sv` je len v example projekte, nie v root RTL. To je podľa mňa správne, lebo stub je demo/test IP, nie core knižnica.

---

# Čo by som teraz spravil

## 1. Malý dokumentačný cleanup commit

```text id="8e1osz"
docs/xfcp/README.md:
  Version 1.6 -> 1.7
  Status -> xfcp_lib_v1_7_cpu_stub_pass
  Latest validated example -> xfcp_test_13_cpu_softcore_stub

docs/xfcp/version.md:
  presunúť v1.7 nad v1.6
```

Potom tag, ak ešte nie je:

```text id="brh1ka"
xfcp_lib_v1_7_cpu_stub_pass
```

Tag message:

```text id="yixve7"
XFCP v1.7 — CPU softcore stub

- CPU-side native mailbox porty
- xfcp_cpu_stub demo agent
- PING -> PONG, unknown -> ERR\n
- Sim T01–T54 PASS
- Timing PASS: CLK125 WNS +0.241 ns
- HW UART 102/102 PASS
- HW UDP 102/102 PASS
```

## 2. Stopnúť nové XFCP features

Teraz by som už nepridával ďalší XFCP backend. Máme dosť:

```text id="lv8sro"
AXIL
AXIS
MEM
CAPS
TARGETS
MAILBOX
CPU stub
CLI
```

Toto je výborný základ na pripojenie SDRAM.

---

# Ako prejsť na SDRAM bez rozbitia XFCP

Odporúčam teraz spraviť tvrdú hranicu:

```text id="6j6wa8"
XFCP baseline:
  xfcp_lib_v1_7_cpu_stub_pass
```

A SDRAM riešiť ako samostatnú knižnicu:

```text id="z7f6s4"
sdram_lib_v0_x
```

Nie priamo v XFCP.

Až keď SDRAM prejde vlastnými míľnikmi, spravíme integračný projekt:

```text id="8fk0xi"
xfcp_sdram_test_01
```

kde sa vymení testovací `axifull_sram.sv` za SDRAM controller na MEM backende.

---

## Záver

Áno, XFCP môžeme považovať za „dokončený baseline“ pre ďalšiu etapu.

Posledné upratanie:

```text id="qsdhwk"
1. docs README aktualizovať z v1.6 na v1.7
2. version.md zoradiť tak, aby v1.7 bolo hore
3. tag/freeze xfcp_lib_v1_7_cpu_stub_pass
```

Potom by som prešiel na SDRAM mini projekt. XFCP už má presne to, čo na SDRAM integráciu potrebujeme: stabilný `MEM_READ/MEM_WRITE` backend, target discovery, CLI a overené UART/UDP transporty.
