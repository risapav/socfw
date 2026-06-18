# sdram_test_01 — SDRAM Library Bring-up

## Aktuálny stav: **IN PROGRESS — sdram_test_06_hw_bist (M1–M5b PASS, regression 6/6)**

---

## Goal

Vytvoriť znovupoužiteľnú SDR SDRAM knižnicu pre socfw.
Mini projekt je nezávislý od XFCP.

Target HW:
- Board: QMTECH EP4CE55F23C8
- SDRAM: Winbond W9825G6KH-6 (16-bit, 4 banky, 8192 riadkov)
- Dátová šírka: 16-bit
- Clock target: 100 MHz (neskôr 125 MHz)

Out of scope:
- XFCP integrácia
- UDP transport
- mailbox / CLI

---

## Milestone plán

| Míľnik | Popis | Stav |
|--------|-------|------|
| `sdram_test_01_init_refresh` | init sekvencia + periodický refresh | **PASS 2026-06-17** |
| `sdram_test_02_single_rw` | jeden write/read bez AXI | **PASS 2026-06-17** |
| `sdram_test_03_scheduler_rw` | scheduler + bank_machine + timing | **PASS 2026-06-18** |
| `sdram_test_04_axi_single_rw` | AXI 32-bit single write/read | **PASS 2026-06-18** |
| `sdram_test_05a_axi_burst_rw` | AXI 2-beat burst, RLAST, bez backpressure | **PASS 2026-06-18** |
| `sdram_test_05b_axi_backpressure` | RREADY stall, skid buffer drain | **PASS 2026-06-18** |
| `sdram_test_06_hw_bist` | FPGA BIST smoke test | TODO |

---

## Míľnik: sdram_test_01_init_refresh — **PASS (2026-06-17)**

### Cieľ

Overiť iba:
- 200 µs init wait (20000 cyklov @ 100 MHz)
- PRECHARGE ALL (A10=1)
- AUTO REFRESH × 8
- MODE REGISTER SET (addr=0x0030: BL=1, CAS=3)
- init_done assert
- periodický refresh po init_done

### Moduly v DUT

```
sdram_pkg.sv          -- parametre, CMD enum, typy
sdram_init.sv         -- 9-stavový init FSM
refresh_manager.sv    -- kreditný refresh generátor
sdram_phy.sv          -- command register + DQ tristate + CAS pipeline
```

### Simulation model

```
sim/model/sdram_model_pro.sv   -- timing checker (tRCD, tRP, tRAS, tWR, tRFC)
sim/sdram_cmd_trace.sv         -- farebný log príkazov
```

### Definition of done

```
sim PASS:
  cnt_pre_all == 1
  cnt_ref     >= 11  (8 init + min 3 periodic)
  cnt_mrs     == 1
  cnt_act     == 0, cnt_rd == 0, cnt_wr == 0
  sekvenciu: PRE_ALL → REF × 8 → MRS → init_done → periodic REF
  MRS addr == 13'h0030
  žiadne $error z sdram_model_pro
```

### Sim výsledok

```
Questa 2025.2, 2026-06-17
PRE_ALL=1  REF=19  MRS=1  ACT=0  RD=0  WR=0
Seq: PRE_ALL@200us  REF@200us  MRS@200.9us  init_done@200.9us
Periodic REF: delta=780 cyklov (T_REFI OK)
MRS addr: 0x0030 (BL=1 sequential, CAS=3) OK
sdram_model_pro: Errors: 0, Warnings: 0
*** PASS ***
```

---

## RTL štruktúra (celá knižnica)

```
rtl/sdram/
  sdram_pkg.sv           -- centrálne parametre, mapping, príkazy
  sdram_init.sv          -- init FSM: 200us → PRE_ALL → 8x REF → MRS
  refresh_manager.sv     -- kreditný refresh (T_REFI=780 cyklov)
  sdram_phy.sv           -- PHY: command register, DQ tristate, CAS pipeline
  timing_manager.sv      -- tRCD/tRP/tRAS/tRFC/tWR/tWTR countery
  bank_machine.sv        -- open-row tracking pre 4 banky
  memory_scheduler.sv    -- FSM scheduler (ACT/RD/WR/PRE/REF)
  write_engine.sv        -- AXI W → SDRAM WR gearbox
  read_engine.sv         -- SDRAM RD → AXI R pipeline
  sdram_system_top.sv    -- kompletný top s AXI

rtl/axi/
  axi_frontend.sv        -- AXI AR/AW arbitrácia
  axi_gearbox.sv         -- 32-bit AXI → 16-bit SDRAM gear

rtl/fifo/
  sync_fifo.sv           -- generický sync FIFO
```

---

## Známe problémy (zo statickej analýzy, navrh_02.md)

1. `read_engine` — issue_id/issue_last môže zachytiť stale hodnoty (latched vs direct)
2. `read_engine` — neúplná AXI R backpressure ochrana (rready=0 + nový beat)
3. `write_engine` — BVALID príliš skoro (po prijatí do FIFO, nie po reálnom SDRAM WR)
4. `memory_scheduler` — bank-pipeline optimalizácia bez skutočného FIFO lookaheadu
5. `sdram_model_pro` — chýba overenie init sekvencie, tREFI watchdog, MRS decode

Tieto budú riešené postupne v milstonoch 2–5.

---

## Míľnik: sdram_test_05b_axi_backpressure — **PASS (2026-06-18)**

### Cieľ

Overiť skid buffer v `read_engine` pri RREADY=0 stalle počas 2-beat burstu.
Oba beaty musia byť zachované a drainované v správnom poradí po RREADY=1.

### RTL zmena (read_engine.sv v160)

- Pridaný 1-entry skid buffer (`skid_rdata/rid/rlast/valid`)
- AXI R output register + skid v samostatnom `always_ff`
- Routing: beat_valid → output (ak voľný) alebo skid (ak busy)
- Drain: pri rready && rvalid && skid_valid → skid do output

### Sim výsledok

```
Questa 2025.2, 2026-06-18
RVALID_drops=0  (AXI protocol: RVALID stabilny pocas stallu)
ACT=1  WR=4  RD=4  PRE=0
Beat0: 0xdeadbeef  rlast=0  rid=0x5  (zo skid output registra)
Beat1: 0x12345678  rlast=1  rid=0x5  (zo skid registra po drainu)
sdram_model_pro: vsetky prikazy OK
*** PASS ***
Regression: 6/6 PASS
```

### Zname obmedzenie

Skid buffer ma kapacitu 1 entry. Overflow ak RREADY=0 dlhsie nez inter-beat interval
(~3 clk cykly pre back-to-back RD). Pre dlhsie bursts alebo horsiu backpressure treba
plnohodnotny R FIFO.

---

## Míľnik: sdram_test_05a_axi_burst_rw — **PASS (2026-06-18)**

### Cieľ

AXI 2-beat burst write/read (AWLEN=1, ARLEN=1). RREADY=1, BREADY=1 (bez backpressure).
Overenie správneho RLAST[0]=0, RLAST[1]=1 a dátovej integrity cez gearbox.

### RTL oprava pred M5a

`read_engine.sv`: pridaný `read_cmd_phase` toggle flip-flop.
Meta FIFO push zmenený z `read_issue && issue_last` na `read_issue && read_cmd_phase`.

**Prečo**: Pre burst reads (ARLEN>0) sa na každý AXI beat emitujú 2 CMD_RDs (phase0, phase1).
Predtým push iba pri `issue_last=1` = len pre phase1 posledného beatu → meta FIFO underflow
pre non-last beaty. Nová podmienka pushuje raz za beat (pri každom phase1 CMD_RD). ✓

### Sim výsledok

```
Questa 2025.2, 2026-06-18
ACT=1  WR=4  RD=4  PRE=0
Beat0: 0xdeadbeef  rlast=0  rid=0x5
Beat1: 0x12345678  rlast=1  rid=0x5
sdram_model_pro: vsetky prikazy OK (tWTR, row-hit)
*** PASS ***
Regression: 5/5 PASS
```

### SDRAM command trace

```
ACT    B0 Row:0010
WR     B0 Col:008  (OK)  <- 0xBEEF (low beat0)
WR     B0 Col:009  (OK)  <- 0xDEAD (high beat0)
WR     B0 Col:00A  (OK)  <- 0x5678 (low beat1)
WR     B0 Col:00B  (OK)  <- 0x1234 (high beat1)
RD     B0 Col:008  (OK)
RD     B0 Col:009  (OK)
RD     B0 Col:00A  (OK)
RD     B0 Col:00B  (OK)
```

---

## Míľnik: sdram_test_04_axi_single_rw — **PASS (2026-06-18)**

### Cieľ

Overiť kompletný AXI stack: write_engine + read_engine + axi_gearbox + axi_frontend + memory_scheduler.
Jeden 32-bit AXI write (AWLEN=0) + read (ARLEN=0), RREADY=1, BREADY=1 (bez backpressure).

### Moduly v DUT

```
sdram_system_top.sv — full AXI controller (všetky sub-moduly)
```

### Adresovanie

AXI addr mapping (DATA_WIDTH=16): [0]=byte_offset, [9:1]=col, [11:10]=bank, [24:12]=row
Test: bank=0, row=0x10, col=8 → AXI_TEST_ADDR=32'h0001_0010
WDATA=32'h1234_A5C3: phase0→0xA5C3@col8, phase1→0x1234@col9

### RTL opravy pred M4

1. `sdram_system_top.sv`: issue_id_lat/issue_last_lat registre odstránené, read_engine
   dostáva `fifo_cmd.id` / `fifo_cmd.last` priamo (kombinačne = correct active-region NBA)
2. `axi_gearbox.sv`: m_cmd.last pre read mode = `(gear_state==GS_PHASE1) && (aw_burst_cnt==0)`
   (predtým: `last_latch && GS_PHASE1` — last_latch nikdy nastavený v READ mode → RLAST=0)
3. `read_engine.sv`: meta_fifo push = `read_issue && issue_last` (nie len `read_issue`)
   (predtým: 2 push na beat → pop vytiahol fázu0 s last=0 → RLAST=0)

### Sim výsledok

```
Questa 2025.2, 2026-06-18
ACT=1  WR=2  RD=2  PRE=0
Write=0x1234a5c3  Read=0x1234a5c3  rlast=1  rid=0x5
sdram_model_pro: (OK) pri všetkých príkazoch — žiadne timing violations
*** PASS ***
Regression: 4/4 PASS
```

### SDRAM command trace (po init)

```
ACT    B0 Row:0010
WR     B0 Col:008  (OK)
WR     B0 Col:009  (OK)   ← tWTR=1 cycle (row-hit)
RD     B0 Col:008  (OK)   ← tWTR=2 cycles od posledného WR
RD     B0 Col:009  (OK)   ← row-hit, ihneď po phase0
```

### Známe obmedzenia (won't fix v M4)

- BVALID fires po gearbox phase1 (nie po reálnom SDRAM WR complete)
- read_engine bez R backpressure skid buffer (RREADY=1 v TB)

---

## Míľnik: sdram_test_03_scheduler_rw — **PASS (2026-06-18)**

### Cieľ

Overiť `memory_scheduler + timing_manager + bank_machine` bez AXI, bez write/read engine, bez FIFO.
TB posiela `sdram_cmd_t` priamo do schedulera (direct command driver).

### Moduly v DUT

```
sdram_pkg.sv, sdram_init.sv, sdram_phy.sv
timing_manager.sv, bank_machine.sv (x4), memory_scheduler.sv
```

### Obmedzenia

- Bank pipeline disabled (single-bank test)
- refresh_req = 1'b0
- Jeden command stream: WRITE → READ (row-hit)

### Sim výsledok

```
Questa 2025.2, 2026-06-18
ACT=1  WR=1  RD=1  PRE=0
Write=0xa5c3  Read=0xa5c3  valid=1
sdram_model_pro: Errors=0, Warnings=0
*** PASS ***
Regression: 3/3 PASS
```

### Klúčové poznatky

- `read_en_in` je kombinačný (= sched_valid_w && CMD_RD): clk_sh pred clk posedge T_rd
  vidí post-NBA stav (twtr=0, ST_IDLE) → sched_valid=1 → read_en_sh zachytené o 1 clk_sh skôr ako model
- `dq_oe_hold`: registrovaná 1-cyklová predĺžka dq_oe po CMD_WR — model's clk_sh +7.5ns zachytí DQ
- `while (!sched_ready) @(posedge clk); #1` — bezpečný consume pattern (read_en_sh már zachytené)

---

## Míľnik: sdram_test_02_single_rw — **PASS (2026-06-17)**

### Cieľ

PHY-level single 16-bit write + read bez schedulera a AXI.
TB riadi sdram_phy priamo (mux: init_busy → init, inak TB).

### Moduly v DUT

```
sdram_pkg.sv, sdram_init.sv, sdram_phy.sv   (bez refresh_manager)
```

### Sim výsledok

```
Questa 2025.2, 2026-06-17
ACT=2  WR=1  RD=1  PRE=2
Write=0xa5c3  Read=0xa5c3  valid=1
sdram_model_pro: Errors=0, Warnings=0
*** PASS ***
```

### Klúčové poznatky o timing

- `clk_sh` predchádza `clk` o 2.5 ns (nie za ním)
- PHY registruje CMD na `clk`, model vidí cmd na najbližšom `clk_sh` po `clk` = 1 `clk_sh` neskôr
- Model zachytáva DQ (write) blokovacím priradením pri rovnakom `clk_sh` ako vidí CMD_WR:
  `mem[idx] = dq` — DQ musí byť platné až do tohto momentu (2 clk cykly po TB drive)
- PHY CAS pipeline: `read_en_in` → `clk_sh` register → shift[CAS+2] → capture → `clk` sync
  Skutočná latencia v TB cykloch: CAS_LATENCY + 5 = 8 od RD drive (nie CAS+2 ako v docs)
