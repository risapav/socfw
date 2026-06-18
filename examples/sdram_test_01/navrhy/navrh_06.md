Nie — pri poslednej odpovedi som si tým **nemal byť istý**. Po tvojej námietke som aktuálny ZIP skontroloval znova priamo zo súboru a predchádzajúci záver bol nesprávny.

## Správny hash aktuálneho ZIPu

```text
SHA-256: 0ce6503b7312b08ec10566142716be4975342c4800c1c22624e532b6b67c1371
Veľkosť: 895 492 B
Počet položiek: 141
```

Toto je **novší snapshot** než ten, ktorý som predtým vyhodnotil.

## Správny aktuálny stav

```text
[PASS] sdram_test_01_init_refresh
[PASS] sdram_test_02_phy_single_rw
[PASS] sdram_test_03_scheduler_rw
[PASS] sdram_test_04_axi_single_rw
[PASS] sdram_test_05a_axi_burst_rw
[PASS] sdram_test_05b_axi_backpressure
[TODO] sdram_test_06_hw_bist
```

`STATUS.md` uvádza:

```text
IN PROGRESS — sdram_test_06_hw_bist (M1–M5b PASS, regression 6/6)
```

A logy to potvrdzujú.

## Nové PASS dôkazy

### M4 — AXI single RW

```text
ACT=1 WR=2 RD=2 PRE=0
Write=0x1234a5c3  Read=0x1234a5c3  rlast=1  rid=0x5
*** PASS ***
Errors: 0, Warnings: 0
```

### M5a — AXI 2-beat burst RW

```text
ACT=1 WR=4 RD=4 PRE=0
Beat0: 0xdeadbeef  rlast=0  rid=0x5
Beat1: 0x12345678  rlast=1  rid=0x5
*** PASS ***
Errors: 0, Warnings: 0
```

### M5b — AXI R backpressure

```text
RVALID_drops=0
ACT=1 WR=4 RD=4 PRE=0
Beat0: 0xdeadbeef  rlast=0  rid=0x5
Beat1: 0x12345678  rlast=1  rid=0x5
*** PASS ***
Errors: 0, Warnings: 0
```

## Dôležité RTL zmeny sú už prítomné

Predtým spomínaný `read_issue` metadata problém je v tomto snapshot-e opravený:

```systemverilog
.issue_id(fifo_cmd.id),
.issue_last(fifo_cmd.last),
```

`read_engine.sv` už má aj 1-entry skid buffer:

```text
read_engine.sv (v160)
AXI Read Datapath s Gearboxom a skid bufferom
```

A metadata FIFO push je už upravený pre burst read:

```systemverilog
.s_valid(read_issue && read_cmd_phase)
```

Čiže moja predchádzajúca výhrada k tomuto ZIPu bola neaktuálna.

## Čo ešte ostáva

Projekt je teraz reálne v stave:

```text
M1–M5b simulation PASS
ďalší krok: M6 HW BIST
```

Stále však platia tieto limity:

```text
1-entry R skid buffer zvládne krátky stall, nie dlhý backpressure pri dlhších burstoch
write_engine BVALID je stále skôr „accepted by controller“, nie nutne „committed to SDRAM“
scheduler testy zatiaľ nekryjú row miss, refresh under load, multi-bank pipeline
Quartus/HW smoke test ešte nie je doložený
```

## Opravený verdikt

SDRAM knižnica spravila výrazný progres. Už nie je na M3 ani M4 — aktuálny snapshot je:

```text
sdram_lib simulation: 6/6 PASS
next milestone: FPGA HW BIST smoke test
```

Máš pravdu, bolo namieste zapochybovať.
