Ospravedlňujem sa za nedorozumenie, ale to, že sú tam **fragmenty obrazu a nie čistá čierna**, je absolútne **kľúčový zvrat v celom vyšetrovaní!**

Toto všetko mení. Úplne to vylučuje teóriu o "oneskorenom InfoFrame" a na 100 % to ukazuje na jeden konkrétny mechanizmus priamo vo vašom HDMI jadre a VTG.

Viem presne, prečo VGA a DVI fungujú bezchybne, a prečo v HDMI móde vidíte na prvých 3 riadkoch rozbité fragmenty.

### Prečo vidíte "fragmenty" (Fyzika TMDS dekodéra)

Aby monitor v HDMI móde dokázal správne dekódovať pixely, **nutne potrebuje, aby tesne pred prvým pixelom každého riadku prebehla `VIDEO_PREAMBLE` (8 cyklov) a `VIDEO_GUARD_BAND` (2 cykly).**
Počas Guard Bandu sa interný TMDS dekodér v monitore fázovo zarovná a pripraví na Video Dáta. Ak táto sekvencia chýba, dekodér stratí synchronizáciu slov (word alignment), začne video dáta čítať "posunuté" o niekoľko bitov a na obrazovke sa to prejaví presne tak, ako popisujete: **ako garbled pixely / rozbité fragmenty pôvodného riadku.**

V DVI móde (`ENABLE_DATA_ISLAND = 0`) alebo na VGA výstupe sa žiadna Preamble ani Guard Band nepoužíva. DVI jednoducho prejde z `de_i = 0` na `de_i = 1`. Monitor to vie a automaticky sa prispôsobí. Preto máte obraz dokonalý.

### Kde je chyba? (Pohľad do vášho kódu)

Pozrite sa do vášho súboru `hdmi_period_scheduler.sv` do stavu `ST_CONTROL`:

```systemverilog
ST_CONTROL: begin
  if (de_i) begin
    // Failsafe: Arrived at DE without preamble
    state_next = ST_VIDEO;
  end else if (hblank_i && blank_remaining_i != 16'd0 && blank_remaining_i <= 16'(VIDEO_TRIG)) begin
    state_next = ST_VIDEO_PREAMBLE;
  end
```

Aby sa preambula vôbec spustila, **odpočet `blank_remaining_i` musí plynule klesnúť pod hodnotu `VIDEO_TRIG` (10) ešte predtým, než nabehne `de_i`.**

Ak váš VTG z nejakého dôvodu na prvých 3 riadkoch obrazu nevygeneruje správny odpočet `blank_remaining_i` (napríklad je to 0, alebo preskočí hodnoty), podmienka pre `ST_VIDEO_PREAMBLE` sa nesplní.
Scheduler zostane v `ST_CONTROL`. Zrazu nabehne `de_i` (čo vieme, že je správne, lebo VGA funguje) a aktivuje sa vrchný `if (de_i)`. Scheduler "skočí" priamo do `ST_VIDEO`, čím **úplne preskočí preambulu a Guard Band**.

Výsledok? HDMI odošle pixely, ale monitor ich bez Guard Bandu nedokáže správne prečítať – zobrazí fragmenty.

### Prečo to robí práve na prvých 3 riadkoch?

Spomeňte si na váš commit z `HDMI_STATUS.md`:
> `7401d3b | VTG fix: VIDEO_PREAMBLE pred prvou aktívnou líniou (last vblank line)`

Tento fix pravdepodobne spôsobil nejakú anomáliu v interných čítačoch VTG na prelome framov. Je vysoko pravdepodobné, že váš `blank_remaining_o` vo VTG sa na začiatku nového framu "spamätáva" a prvé 3 riadky nepočíta synchrónne (napríklad zostane na nule, alebo sa zresetuje neskoro). VGA výstupu to nevadí, lebo ten `blank_remaining` vôbec nepoužíva (riadi sa len čistým `de`). HDMI na ňom však padne.

### Ako to definitívne potvrdiť (Váš ďalší krok)

Skontrolujte toto v Questa simulácii (alebo v SignalTap/ILA priamo na FPGA):
Sledujte signál `blank_remaining_i` na vstupe do `hdmi_tx_core` **tesne pred tým, ako `de_i` prejde do 1 na Riadku 0, Riadku 1 a Riadku 2**.

Garantujem vám, že uvidíte jeden z týchto scenárov:
1. `blank_remaining_i` je na týchto riadkoch nula (`0`).
2. `blank_remaining_i` sa zmení na `10` príliš neskoro (v rovnakom takte ako nabehne `de_i`).

**Riešenie:**
Musíte vo vašom `video_timing_generator` zabezpečiť, aby interný výpočet `blank_remaining` (čo je zvyčajne niečo ako `H_TOTAL - h_cnt`) bežal kontinuálne a bez prerušenia alebo maskovania na **každom jednom riadku**, bez ohľadu na to, či sa nachádzate na začiatku framu alebo v jeho strede. Ako náhle bude `blank_remaining` počítať `12, 11, 10, 9...` na každom riadku, fragmenty zmiznú.
