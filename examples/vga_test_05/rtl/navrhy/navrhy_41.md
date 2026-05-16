Tento problém – keď čisté DVI video funguje, ale po zapnutí HDMI Data Islands (zvuk, InfoFrames) obraz úplne vypadne – je absolútnou klasikou pri vývoji HDMI vysielačov.

Keď porovnáme tvoj projekt (Prvý) s referenčným projektom od Sameera Puriho (Druhý), z hľadiska **algoritmov a zarovnania (pipeline alignment)** je tvoj kód paradoxne **lepší a robustnejší**. Avšak v prvom projekte máš **dve kritické chyby v definícii HDMI štandardu**, kvôli ktorým monitor nedokáže rozpoznať, kedy sa končí Data Island a kedy začína obraz.

Tu je podrobné porovnanie a presná identifikácia tvojich bugov:

### 1. Porovnanie: Zarovnanie (Pipeline Alignment)

* **Druhý projekt (Puri):** Nemá vlastný zosynchronizovaný FSM (scheduler). Spolieha sa na to, že mu nadradený modul v správny čas zmení signál `mode` (0=control, 1=video, 2=video_guard atď.). Ak sa nadradený modul oneskorí o 1 takt, video sa rozpadne.
* **Tvoj projekt:** Máš excelentne zvládnutú latenciu. Tvoj `hdmi_period_scheduler.sv` presne počíta s `VIDEO_TRIG = 10` a využíva `blank_remaining_rr`. Detailne som to prepočítal (T+10 z VTG, plus 3 takty latencie do TMDS encodéra) a **tvoje zarovnanie je matematicky perfektné**. Keď sa na výstupe `tmds_video_encoder` objaví prvý validný pixel, `hdmi_channel_mux` v tom istom takte prepne na `HDMI_PERIOD_VIDEO`. Tu bug nie je.

### 2. Porovnanie: TMDS Kódovanie (Encoding)

* **Druhý projekt:** Počíta TMDS disparitu a DC-balancovanie vo vnútri jedného masívneho `always_comb` bloku. Je to ťažšie na dosiahnutie vysokých frekvencií (Fmax) vo veľkých FPGA.
* **Tvoj projekt:** Tvoj 2-fázový pipelined encoder (`tmds_video_encoder.sv`) je ukážkový. Rozdelenie výpočtu počtu jednotiek (`count_ones8`) a následného uplatnenia DC-balancie do dvoch registrových fáz je presne to, čo Quartus potrebuje pre 1080p/4K frekvencie.

---

### 🚨 Nájdené Bugy v Tvojom Kóde (Prečo padá video)

Chyba sa nachádza v súbore **`hdmi_channel_mux.sv`**. Nesprávne si interpretoval tabuľky z HDMI špecifikácie (sekcie 5.2.2.1 a 5.2.1) pre **Preambuly** a **Guard Bands (Ochranné pásma)**. Keď je `ENABLE_DATA_ISLAND=1`, tvoj mux začne do linky posielať "neexistujúce" preambuly a nesprávne Guard Bands, takže monitor netuší, že má začať kresliť pixely a obrazovku zhasne.

#### Bug 1: Zlý Video Guard Band (Najkritickejšia chyba)

Pozri sa, ako definuje Video Guard Band tvoj kód a ako Puriho kód (podľa HDMI špecifikácie):

* **HDMI Spec / Puri:** Ch0 = `10'b1011001100`, Ch1 = `10'b0100110011`, Ch2 = `10'b1011001100`.
* **Tvoj kód:** Ch1 a Ch2 dostávajú `10'b1011001100` a na Ch0 posielaš naďalej riadiace signály (`ctrl_ch0_i`).

Keď monitor čaká na Video Guard Band, očakáva ho na všetkých troch kanáloch v presnom vzore. Tým, že na Ch0 nechávaš Control signály, monitor si myslí, že Control Period stále pokračuje.

**Ako to opraviť v `hdmi_channel_mux.sv`:**

```systemverilog
      // PÔVODNÝ ZLÝ KÓD:
      // HDMI_PERIOD_VIDEO_GB: begin
      //   ch2_next = GB_VIDEO;
      //   ch1_next = GB_VIDEO;
      //   ch0_next = ctrl_ch0_i;
      // end

      // OPRAVENÝ KÓD:
      HDMI_PERIOD_VIDEO_GB: begin
        ch2_next = GB_VIDEO;     // 10'b1011001100
        ch1_next = GB_DATA_N;    // 10'b0100110011 (Pattern pre Ch1 je rovnaký ako Data GB!)
        ch0_next = GB_VIDEO;     // 10'b1011001100 (Ch0 nesmie niesť control, ale GB!)
      end

```

#### Bug 2: Totálne chybná Preambula pre Data Island

V tvojom kóde máš komentár:
`// data preamble: CTL2=1, CTL3=1 -> ctrl(2'b11) = 10'b1010101011`
A následne aplikuješ `2'b11` na **Ch1** a nechávaš `2'b00` na **Ch2**. Toto je hlboké nepochopenie špecifikácie.

HDMI špecifikácia mapuje riadiace signály takto:

* Ch0 nesie HSYNC a VSYNC.
* **Ch1 nesie CTL0 a CTL1.**
* **Ch2 nesie CTL2 a CTL3.**

Preambula pre Data Island vyžaduje vzor: `CTL0=1, CTL1=0, CTL2=1, CTL3=0`.
To znamená, že **Ch1** má posielať `2'b01` a **Ch2** má posielať `2'b01`. Tvoj kód posielal `2'b11` na Ch1 a `2'b00` na Ch2, čo je pre monitor neznámy signál.

**Ako to opraviť v `hdmi_channel_mux.sv`:**

```systemverilog
      // PÔVODNÝ ZLÝ KÓD:
      // localparam tmds_word_t PRE_DATA_CH1  = 10'b1010101011;  // ctrl(2'b11)
      // ...
      // HDMI_PERIOD_DATA_PREAMBLE: begin
      //   ch2_next = ctrl_ch2_i;
      //   ch1_next = PRE_DATA_CH1;
      //   ch0_next = ctrl_ch0_i;
      // end

      // OPRAVENÝ KÓD:
      HDMI_PERIOD_DATA_PREAMBLE: begin
        // Obidva kanály musia niesť ctrl(2'b01), čo je 10'b0010101011 (rovnaké ako Video Preamble Ch1)
        ch2_next = PRE_VIDEO_CH1;
        ch1_next = PRE_VIDEO_CH1;
        ch0_next = ctrl_ch0_i;
      end

```

*(Poznámka: Preambula pre video ti doteraz fungovala iba čistou náhodou, pretože Video Preambula vyžaduje CTL0=1, CTL1=0, CTL2=0, CTL3=0, čo sa ti presne trafilo do tvojho pôvodného predpokladu, že Ch2 je proste vždy 0 a Ch1 nesie všetko).*

### Zhrnutie

Tvoja architektúra je po implementačnej stránke lepšia ako referenčný Puriho repozitár, pretože využíva explicitné pipelining fázy. Akonáhle urobíš tieto dve vyššie uvedené zmeny v `hdmi_channel_mux.sv`, monitor pošle správny Handshake, zamkne si Data Islands aj Video fázu a obraz ti po zapnutí zvuku už nezhasne.
