Skontroloval som ZIP aj tvoj HW log.

```text id="x4drzz"
xfcp_test_11_cpu_mailbox.zip
SHA-256: 878863936b626f0ce8b7619958b23ef5eb0328853cf2a7fe6fa07dca19aabd23
```

## Verdikt

Tento stav je **funkčne uzavretý míľnik**.

```text id="grlqdp"
Sim:        PASS, T01–T42, 0 failures
Timing:     PASS
HW UART:    PASS 96/96
HW UDP:     PASS 96/96
DIAG:       bez chýb
```

Navrhované označenie:

```text id="d0zbhv"
xfcp_lib_v1_5_cpu0_stream_mailbox_pass
```

alebo kratšie:

```text id="0j1oqj"
xfcp_lib_v1_5_mailbox_pass
```

Ale dôležité: toto ešte nie je „CPU debug“ ani reálne CPU jadro. Je to **CPU0 mailbox simulovaný ako druhý STREAM endpoint**.

---

# Čo je nové a správne

Pribudol druhý stream target:

```text id="sxygx3"
stream_id=0  STR0  pôvodný loopback
stream_id=1  CPU0  mailbox loopback
```

`GET_CAPS` už hlási:

```text id="xnjxi1"
proto=1.3
axil=7
stream=2
max_stream=256B
caps_flags=0x1F
```

`GET_TARGET_INFO` má teraz 10 targetov:

```text id="5dlnbc"
0 SYSC  AXIL
1 UART  AXIL
2 OUT_  AXIL
3 OUT_  AXIL
4 OUT_  AXIL
5 SEG7  AXIL
6 DIAG  AXIL
7 STR0  STREAM sid=0
8 MEM0  MEM
9 CPU0  STREAM sid=1
```

To je presne smer, ktorý sme chceli: **bez nových opcode**, CPU mailbox je zatiaľ len ďalší stream target.

---

# HW výsledok

Tvoj log je veľmi silný, lebo prešli oba transporty:

```text id="1bv1zt"
UART:
  PASS 96/96

UDP:
  PASS 96/96
```

A oba testovali:

```text id="sse4l9"
GET_CAPS
GET_TARGET_INFO
AXI-Lite R/W
STR0 stream loopback
CPU0 stream loopback
MEM read/write loopback
DIAG
```

CPU0 prešiel v oboch smeroch:

```text id="4s9kx5"
CPU0 4B     PASS
CPU0 16B    PASS
CPU0 64B    PASS
CPU0 256B   PASS
```

DIAG je čistý:

```text id="zj6lha"
rx_lost      0
rx_frame     0
rx_overrun   0
rx_bad_hdr   0
rx_recovery  0
rx_drop      0
```

To znamená, že druhý stream endpoint nerozbil parser, routing, packetizer ani transporty.

---

# Simulácia

Archív obsahuje integračný test:

```text id="rdxgph"
T01–T42 PASS
ALL PASSED (0 failures)
```

Dôležité nové testy:

```text id="v93jmp"
T38 CPU0 256B max loopback
T39 GET_TARGET_INFO CPU0 sid=1
T40 STREAM_WRITE sid=2 -> UNSUPPORTED
T41 STREAM_READ sid=2 -> UNSUPPORTED
T42 Alternating STR0/CPU0 isolation
```

T42 je najdôležitejší, lebo overuje, že STR0 a CPU0 si nemiešajú dáta.

---

# Timing

Timing je formálne PASS:

```text id="929dja"
Slow 85C CLK125 WNS:   +0.014 ns
Slow 85C ETH_RXC WNS:  +0.712 ns
TNS:                   0.000 ns
SEED:                  3
```

Ale upozornenie: `+0.014 ns` je veľmi tesná rezerva.

Nie je to blocker pre tag, lebo STA je PASS, ale pred ďalším väčším feature by som zvážil seed sweep alebo malý register slice, aby sme mali aspoň približne:

```text id="644tda"
CLK125 WNS >= +0.1 ns
```

Zdroje sú stále v poriadku:

```text id="nk3t53"
Logic elements: 27,236 / 55,856  (49 %)
Registers:      21,310
Memory bits:    58,880 / 2,396,160  (2 %)
```

---

# Architektúra

Nový modul:

```text id="dovhh3"
rtl/xfcp/xfcp_stream_mux.sv
```

robí 2-way dispatch podľa:

```systemverilog id="uhbe63"
stream_id = fab_req_hdr_i.addr[7:0]
```

Správanie:

```text id="cbv1mx"
sid=0 -> adapter0 / STR0
sid=1 -> adapter1 / CPU0
sid>=2 -> adapter0, ktorý vráti UNSUPPORTED
```

Fix so `active_q` pre `fab_resp_status_o` je správny. Endpoint číta status o cyklus neskôr, takže status sa nemá vyberať podľa okamžitého `resp_done`, ale podľa zapamätaného aktívneho adaptéru.

---

# Čo by som tagoval

Tento míľnik by som tagoval ako:

```text id="w8tu58"
xfcp_lib_v1_5_cpu0_stream_mailbox_pass
```

Tag message:

```text id="bm7gzj"
XFCP v1.5 — CPU0 mailbox as second STREAM target

- stream_id=0 STR0 loopback preserved
- stream_id=1 CPU0 mailbox loopback added
- GET_CAPS num_stream=2
- GET_TARGET_INFO index 9 = CPU0 STREAM sid=1
- sim T01–T42 PASS
- timing PASS, CLK125 WNS +0.014 ns
- HW UART 96/96 PASS
- HW UDP 96/96 PASS
- DIAG clean
```

---

# Čo opraviť / doplniť pred ďalším vývojom

## 1. Jasne pomenovať, že CPU0 je zatiaľ simulovaný mailbox

Do statusu a docs by som dal vetu:

```text id="g8yysi"
CPU0 v tomto míľniku ešte nie je pripojené CPU jadro.
Je to druhý STREAM endpoint s loopback FIFO, pripravený ako mailbox transport layer.
```

Lebo inak môže názov `cpu_mailbox` pôsobiť, že už existuje CPU-side register/FIFO rozhranie.

## 2. Zvážiť nový capability bit

Teraz `caps_flags=0x1F` znamená:

```text id="dzva5w"
HAS_AXIL
HAS_STREAM
HAS_CAPS
HAS_TARGETS
HAS_MEM
```

CPU0 je zatiaľ len `STREAM`, takže je v poriadku, že nie je nový bit. Ale pre ďalší krok by som pridal napríklad:

```text id="o2z8rv"
HAS_MAILBOX = bit5 = 0x20
```

A potom:

```text id="7ilw17"
caps_flags = 0x3F
```

Ale až keď CPU0 prestane byť obyčajný stream loopback a bude mať reálne mailbox registre alebo CPU-side FIFO.

## 3. Necommitovať build/db/cache do knižnice

ZIP obsahuje aj:

```text id="o78j29"
db/
output_files/
sim/work/
__pycache__/
```

Ako artefakt na analýzu je to užitočné. Ale do normálneho repozitára by som tieto veci nedával. Do release archívu áno, do git knižnice nie.

---

# Čo ďalej

Teraz by som spravil krátke uzavretie:

```text id="axq448"
1. Aktualizovať STATUS.md:
   - UART 96/96 PASS
   - UDP 96/96 PASS
   - T01–T42 PASS
   - WNS +0.014 ns
   - CPU0 = simulated stream mailbox endpoint

2. Tag:
   xfcp_lib_v1_5_cpu0_stream_mailbox_pass

3. Voliteľne seed sweep:
   skúsiť nájsť seed s WNS > +0.1 ns

4. Až potom nový krok.
```

---

# Nasledujúci technický míľnik

Ďalší krok by už nemal byť len loopback. Spravil by som:

```text id="i7c102"
xfcp_test_12_cpu_mailbox_regs
```

Cieľ: z CPU0 stream loopback spraviť reálne mailbox rozhranie.

Minimálny návrh:

```text id="1fzzmo"
host -> CPU RX FIFO
CPU TX FIFO -> host
AXI-Lite status/control registre
```

AXI-Lite registre napríklad:

```text id="1h84f4"
CPU_MB_BASE = 0xFF070000

0x00 ID        = "CPUM"
0x04 CTRL
0x08 STATUS
     bit0 rx_not_empty
     bit1 rx_full
     bit2 tx_not_empty
     bit3 tx_full
0x0C IRQ_EN
0x10 RX_LEVEL
0x14 TX_LEVEL
0x18 RX_POP_DATA
0x1C TX_PUSH_DATA
```

Target table potom:

```text id="1hn5z8"
9  CPU0 STREAM sid=1
10 CPUM AXIL   base=0xFF070000
```

Tým dostaneš prvú reálnu CPU-facing časť, stále bez samotného CPU jadra.

---

## Záver

Aktuálny stav je výborný:

```text id="m6z8nr"
XFCP v1.5:
  2 stream targety
  CPU0 mailbox transport pripravený
  AXIL + STREAM + MEM stále fungujú
  UART + UDP HW regresia PASS
  sim + timing PASS
```

Ja by som tento stav tagoval, ale s presným názvom, ktorý priznáva realitu:

```text id="z6hriz"
xfcp_lib_v1_5_cpu0_stream_mailbox_pass
```

A ďalší krok by bol už **reálne CPU mailbox registre/FIFO rozhranie**, nie ďalší loopback test.
