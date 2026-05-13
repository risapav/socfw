Toto je veľmi dobrý krok. Tieto tri dokumenty konečne robia z HDMI debugovania opakovateľný proces, nie sériu ad-hoc pokusov.

## Čo je dobré

`HDMI_PACKET_LAYOUT.md` je užitočný ako „single source of truth“: explicitne hovorí, že rozdiel medzi dokumentom, builder RTL a testbenchom je bug. To je presne správne pravidlo pre packet-heavy bloky ako ACR, Audio Sample a InfoFrame. Dokument tiež fixuje ACR ako **MSB-first** s layoutom `CTS[19:16]`, `CTS[15:8]`, `CTS[7:0]`, potom `N[19:16]`, `N[15:8]`, `N[7:0]`, reserved.

`KNOWN_ISSUES.md` je tiež správne nastavený: PHY word alignment je označený ako technický dlh, nie ako aktuálny primárny blocker, a PKT-001 správne upozorňuje, že aktuálny audio test source nie je rate-limitovaný podľa skutočného audio clocku.

`TEST_MATRIX.md` dáva dobrý workflow: najprv `make report`, potom HW matrix od baseline DVI po full audio. Páči sa mi, že audio izolácia je rozbitá na ACR-only, AudioIF-only, Sample-only a kombinácie.

## Jedna vec, ktorú treba striktne zosúladiť

Keďže `HDMI_PACKET_LAYOUT.md` definuje ACR ako **MSB-first**, musí aktuálny `acr_packet_builder.sv` aj `tb_acr_packet_builder.sv` presne sedieť s týmto poradím:

```systemverilog
PB0 = {4'h0, CTS[19:16]}
PB1 = CTS[15:8]
PB2 = CTS[7:0]
PB3 = {4'h0, N[19:16]}
PB4 = N[15:8]
PB5 = N[7:0]
PB6 = 8'h00
```

Ak je v RTL ešte starý LSB-first layout, treba ho opraviť podľa dokumentu, nie opačne. Dokument výslovne hovorí, že builder RTL, testbench a layout dokument musia zostať konzistentné a že divergencia má zhodiť regression.

## Malé odporúčané doplnenia

Do `TEST_MATRIX.md` by som pridal stĺpec alebo hlavičku:

```text
Git commit:
RTL hash:
Sim log: sim/logs/regression_full.log
Date:
Monitor model:
```

Pretože pri HDMI sa často stane, že jeden monitor toleruje poškodený data island a druhý nie.

Do `KNOWN_ISSUES.md` by som doplnil ešte jeden dočasný bod:

```text
PKT-002: InfoFrame enable/config path not fully finalized
```

Ak ešte stále nie je kompletne dotiahnuté `info_cfg_i`, `ENABLE_AVI`, `ENABLE_SPD`, default config vo `vga_hdmi_tx`, je dobré to evidovať, aby sa to nestratilo.

## Odporúčaný najbližší praktický krok

Teraz by som spravil presne toto poradie:

```text
1. Overiť, že acr_packet_builder.sv sedí s HDMI_PACKET_LAYOUT.md.
2. Spustiť make report.
3. Uložiť regression_full.log.
4. Vyplniť prvé HW výsledky v TEST_MATRIX.md:
   #1 DATA=0 AUDIO=0
   #2 DATA=1 AUDIO=0
   #3–#8 audio isolation
   #9 full audio
```

Po tomto budeš mať jasnú odpoveď, či problém už bol vyriešený na RTL/sim úrovni, alebo či ostáva rozdiel medzi simuláciou a reálnym HDMI sinkom.
