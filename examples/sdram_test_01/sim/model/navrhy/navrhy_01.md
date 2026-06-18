Analyzoval som `sdram_model_pro.sv`. Ako základný behavioral model je užitočný, ale v aktuálnej podobe má viacero vecí, ktoré môžu viesť k falošným PASS/FAIL výsledkom v simulácii SDRAM radiča.

Najdôležitejšie zistenie: **model je dobrý na jednoduché single-beat READ/WRITE testy, ale ešte nie je dostatočne presný pre bursty, DQM masky, auto-precharge timing, init sekvenciu a reálne SDR SDRAM správanie.**

---

## 1. Čo je na modeli dobré

Používa asociatívnu pamäť:

```systemverilog
logic [DATA_WIDTH-1:0] mem [int];
```

To je pre simuláciu veľmi praktické, lebo nepotrebuješ alokovať celú SDRAM veľkosť. Zároveň nevznikne aliasing, pokiaľ je `mem_addr()` správne.

Dobré je aj to, že sleduješ per-bank stav:

```systemverilog
bank[b].open
bank[b].row
bank[b].rcd_timer
bank[b].ras_timer
bank[b].rp_timer
bank[b].wr_timer
```

a kontroluješ základné timingy:

```text
tRCD
tRP
tRAS
tWR
tRFC
```

Tiež je správny smer mať CAS latency pipeline.

---

# 2. Kritický problém: CAS latency je pravdepodobne posunutá o 1 cyklus

Komentár hovorí:

```systemverilog
// CL+1 stupňov → výstup z cas_pipe[CL] = CL cyklov latencie
```

V kóde však robíš v jednom `always_ff` toto poradie:

```systemverilog
for (int i = CL; i > 0; i--)
  cas_pipe[i] <= cas_pipe[i-1];

cas_pipe[0].valid <= 0;

if (cas_pipe[CL].valid) begin
  dq_out   <= cas_pipe[CL].data;
  dq_drive <= 1;
end

if (cmd_read) begin
  cas_pipe[0].valid <= 1;
  cas_pipe[0].data  <= mem[mem_index];
end
```

Keďže používaš nonblocking assignmenty, `if (cas_pipe[CL].valid)` číta **starú hodnotu** `cas_pipe[CL]`, nie hodnotu po shifte. Výsledkom môže byť latencia o jeden cyklus dlhšia, než čakáš.

Príklad pri `CL=3`:

```text
cyklus N:   READ nastaví cas_pipe[0]
cyklus N+1: cas_pipe[1]
cyklus N+2: cas_pipe[2]
cyklus N+3: cas_pipe[3]
cyklus N+4: dq_drive podľa starej cas_pipe[3]
```

Teda dáta sa môžu objaviť po 4 cykloch, nie po 3.

## Odporúčaná oprava

Najčistejšie je rozdeliť pipeline na next-state alebo vyhodnotiť výstup zo stage, ktorý sa práve posúva do posledného stupňa.

Jednoduchá oprava:

```systemverilog
// Output current last stage first
if (cas_pipe[CL-1].valid) begin
  dq_out   <= cas_pipe[CL-1].data;
  dq_drive <= 1'b1;
end
```

a pipeline mať `CL` stupňov, nie `CL+1`.

Alebo použiť next premennú:

```systemverilog
cas_stage_t cas_next [CL+1];

always_comb begin
  cas_next[0].valid = 1'b0;
  cas_next[0].data  = '0;

  for (int i = 1; i <= CL; i++) begin
    cas_next[i] = cas_pipe[i-1];
  end

  if (cmd_read_ok) begin
    cas_next[0].valid = 1'b1;
    cas_next[0].data  = read_data;
  end
end

always_ff @(posedge clk) begin
  cas_pipe <= cas_next;

  if (cas_next[CL].valid) begin
    dq_out   <= cas_next[CL].data;
    dq_drive <= 1'b1;
  end
end
```

Pre simulátorovú jednoduchosť by som použil skôr samostatný read queue s countdownom.

---

# 3. Chýba SDRAM `cke`, `dqm`, `dq` output enable timing

Reálny SDR SDRAM interface typicky obsahuje:

```text
cke
dqm
dq
addr
ba
ras_n
cas_n
we_n
cs_n
```

Tvoj model nemá:

```text
cke
dqm
```

To znamená:

```text
- nevieš testovať clock enable / self-refresh / power-down,
- nevieš testovať byte masky pri WRITE,
- nevieš testovať DQM latency pri READ,
- nevieš testovať či controller správne maskuje dolný/horný byte.
```

Pre 16-bit SDRAM je `dqm[1:0]` dôležité. Ak controller používa byte-enable, aktuálny model bude zapisovať celé slovo:

```systemverilog
mem[mem_index] = dq;
```

Aj keď by mal zapísať len jeden byte.

## Odporúčanie

Doplniť port:

```systemverilog
input wire [DATA_WIDTH/8-1:0] dqm
```

A pri WRITE:

```systemverilog
logic [DATA_WIDTH-1:0] old_data;
logic [DATA_WIDTH-1:0] new_data;

old_data = mem.exists(mem_index) ? mem[mem_index] : '0;
new_data = old_data;

for (int i = 0; i < DATA_WIDTH/8; i++) begin
  if (!dqm[i]) begin
    new_data[i*8 +: 8] = dq[i*8 +: 8];
  end
end

mem[mem_index] = new_data;
```

---

# 4. Uninitialized read vracia X

Pri READ:

```systemverilog
cas_pipe[0].data <= mem[mem_index];
```

Ak `mem_index` ešte neexistuje, asociatívne pole vráti `X` alebo nedefinovanú hodnotu podľa simulátora.

To môže byť dobré, ak chceš chytiť čítanie neinicializovanej pamäte. Ale často je pri memory modeloch praktické mať parameter:

```systemverilog
parameter bit INIT_TO_ZERO = 1'b1
```

Potom:

```systemverilog
if (mem.exists(mem_index))
  read_data = mem[mem_index];
else
  read_data = INIT_TO_ZERO ? '0 : 'x;
```

Odporúčam doplniť parameter:

```systemverilog
parameter bit UNINIT_READ_X = 1'b1
```

a vedome rozhodnúť.

---

# 5. `mem_addr()` používa `int` a môže pretiecť

Funkcia:

```systemverilog
function automatic int mem_addr(...);
  return int'(ba)  * (1 << ROW_WIDTH) * (1 << COL_WIDTH)
       + int'(row) * (1 << COL_WIDTH)
       + int'(col);
endfunction
```

Pri typických parametroch:

```text
BANKS = 4
ROW_WIDTH = 13
COL_WIDTH = 9
```

max adresa je:

```text
4 × 8192 × 512 = 16,777,216 wordov
```

To sa ešte zmestí do signed 32-bit `int`.

Ale ak zvýšiš rozmery alebo použiješ širšiu SDRAM, môže to pretiecť. Tiež `(1 << ROW_WIDTH)` je 32-bit výraz.

Odporúčam použiť `longint unsigned` ako kľúč:

```systemverilog
logic [DATA_WIDTH-1:0] mem [longint unsigned];

function automatic longint unsigned mem_addr(
  input logic [1:0] ba,
  input logic [ROW_WIDTH-1:0] row,
  input logic [COL_WIDTH-1:0] col
);
  return (longint'(ba)  << (ROW_WIDTH + COL_WIDTH))
       | (longint'(row) << COL_WIDTH)
       | longint'(col);
endfunction
```

Toto je čistejšie a bez násobenia.

---

# 6. `BANKS` parameter nie je úplne všeobecný

Port `ba` je fixne:

```systemverilog
input wire [1:0] ba
```

a `mem_addr()` tiež očakáva 2-bit banku.

Ak máš `BANKS=4`, je to OK. Ale parameter `BANKS` potom nie je plne všeobecný.

Lepšie:

```systemverilog
localparam int BANK_WIDTH = $clog2(BANKS);

input wire [BANK_WIDTH-1:0] ba;
```

Ale pozor: port šírka z parametra v module port liste je v SystemVerilogu OK, len treba `localparam` definovať pred port listom nejde. Riešenie:

```systemverilog
parameter int BANKS = 4,
parameter int BANK_WIDTH = $clog2(BANKS)
...
input wire [BANK_WIDTH-1:0] ba
```

---

# 7. Chýba kontrola illegal bank index

Ak `BANKS < 4` a `ba` je 2-bit, potom `bank[ba]` môže ísť mimo rozsah.

Doplniť:

```systemverilog
if (int'(ba) >= BANKS)
  $error("[SDRAM] Invalid bank index %0d", ba);
```

---

# 8. PRECHARGE single-bank nekontroluje `tRAS` a `tWR`

Pri PRECHARGE ALL robíš:

```systemverilog
if (bank[b].ras_timer > 0) $error("[SDRAM] tRAS violation PRE_ALL");
if (bank[b].wr_timer  > 0) $error("[SDRAM] tWR  violation PRE_ALL");
```

Ale pri single-bank PRECHARGE:

```systemverilog
if (!bank[ba].open) $warning("[SDRAM] PRE on closed bank B%0d", ba);
bank[ba].open     <= 0;
bank[ba].rp_timer <= tRP;
```

Tu chýba:

```systemverilog
if (bank[ba].ras_timer > 0) $error("[SDRAM] tRAS violation PRE B%0d", ba);
if (bank[ba].wr_timer  > 0) $error("[SDRAM] tWR violation PRE B%0d", ba);
```

Toto je dôležitý bug. Controller s príliš skorým PRECHARGE single-bank by nebol zachytený.

---

# 9. Auto-precharge je implementovaný príliš zjednodušene

Pri READ/WRITE:

```systemverilog
if (addr[10]) begin
  bank[ba].open     <= 0;
  bank[ba].rp_timer <= tRP;
end
```

Toto zatvorí banku okamžite v tom istom cykle ako READ/WRITE.

Reálne auto-precharge nenastane okamžite. Musí rešpektovať:

```text
READ auto-precharge: po splnení tRAS a podľa burst/CAS pravidiel
WRITE auto-precharge: po write recovery tWR a burst konci
```

Tvoj model tak môže falošne hlásiť chyby alebo naopak nechytiť chyby pri bank re-use.

Pre jednoduchý controller, ktorý nepoužíva auto-precharge, to nevadí. Ale ak controller používa A10 auto-precharge, model je príliš hrubý.

## Odporúčanie

Ak auto-precharge zatiaľ netestuješ, môžeš radšej dať warning:

```systemverilog
if (addr[10]) begin
  $warning("[SDRAM] Auto-precharge requested; simplified model closes bank immediately");
  ...
end
```

Lepšie je doplniť per-bank `auto_precharge_pending` a timer.

---

# 10. Neimplementuje burst length

SDRAM READ/WRITE zvyčajne používa burst length z mode registera:

```text
BL=1,2,4,8,full page
CL=2/3
sequential/interleaved
```

Model teraz pri READ/WRITE spracuje iba jedno slovo na adrese:

```systemverilog
mem_index = mem_addr(... addr[COL_WIDTH-1:0]);
```

Neexistuje:

```text
mode register
load mode register
burst counter
burst terminate
sequential column increment
DQM počas burstu
```

To je OK pre radič, ktorý robí single-beat prístupy s auto-precharge alebo explicit precharge. Ale nie je to plný SDRAM model.

Doporučenie: do dokumentácie modelu jasne napísať:

```text
Model supports single-beat READ/WRITE commands only.
Burst behavior is not modeled yet.
```

Alebo doplniť burst support.

---

# 11. Chýba LOAD MODE REGISTER

SDRAM init sekvencia typicky obsahuje:

```text
PRECHARGE ALL
AUTO REFRESH
AUTO REFRESH
LOAD MODE REGISTER
```

Command LMR je:

```text
CS=0, RAS=0, CAS=0, WE=0
```

Tvoj decoder má:

```systemverilog
wire cmd_ref = (!cs_n && !ras_n && !cas_n && we_n);
```

ale chýba:

```systemverilog
wire cmd_mrs = (!cs_n && !ras_n && !cas_n && !we_n);
```

Bez toho model nevie kontrolovať, či controller správne nastaví CL/burst length.

Odporúčam pridať aspoň:

```systemverilog
wire cmd_mrs = (!cs_n && !ras_n && !cas_n && !we_n);
```

a uložiť:

```systemverilog
logic mode_loaded_q;
logic [2:0] mode_bl_q;
logic [2:0] mode_cl_q;
```

Minimálne kontrolovať:

```systemverilog
if (cmd_read || cmd_write) begin
  if (!mode_loaded_q) $error("[SDRAM] READ/WRITE before LOAD MODE REGISTER");
end
```

---

# 12. Chýba init/power-up kontrola

Model po resete okamžite dovolí ACTIVE/READ/WRITE. Reálny SDRAM potrebuje power-up/init sekvenciu.

Pre testbench môžeš mať controller, ktorý toto robí. Model by mal vedieť kontrolovať:

```text
- po reset/power-up musí prísť PRECHARGE ALL
- potom refresh count
- potom MRS
- až potom READ/WRITE
```

Odporúčam parameter:

```systemverilog
parameter bit CHECK_INIT_SEQUENCE = 1'b1
```

a jednoduchý stav:

```text
INIT_WAIT_PRE
INIT_WAIT_REF1
INIT_WAIT_REF2
INIT_WAIT_MRS
READY
```

Ale ak nechceš takú presnosť, aspoň warning pri RD/WR pred MRS.

---

# 13. Chýba NOP/DESELECT rozlíšenie a command validity

Ak `cs_n=1`, modul nerobí nič. To je OK ako deselect.

Ak `cs_n=0`, kombinácie príkazov sú:

```text
RAS CAS WE
1   1   1  NOP
0   1   1  ACTIVE
1   0   1  READ
1   0   0  WRITE
0   1   0  PRECHARGE
0   0   1  AUTO REFRESH
0   0   0  LOAD MODE REGISTER
```

Model pokrýva všetko okrem NOP a MRS. NOP netreba robiť, ale pre debug by si mohol mať:

```systemverilog
wire cmd_nop = (!cs_n && ras_n && cas_n && we_n);
```

a unknown command check.

---

# 14. READ počas `wr_timer` sa nekontroluje

Po WRITE nastavuješ:

```systemverilog
bank[ba].wr_timer <= tWR;
```

Potom kontroluješ `tWR` len pri PRE_ALL, nie pri READ/WRITE alebo ACTIVE. Reálne `tWR` hlavne obmedzuje PRECHARGE po WRITE. READ do tej istej banky po WRITE má iné pravidlá závislé od write-to-read timing. Ak tento model chce byť jednoduchý, kontrola tWR pred PRECHARGE stačí, ale pri single PRECHARGE momentálne chýba.

---

# 15. DQ contention nie je kontrolovaný

Model riadi `dq` pri read:

```systemverilog
assign dq = dq_drive ? dq_out : 'z;
```

Ale nekontroluje, či controller náhodou stále riadi DQ počas READ. Pri inout zvyčajne ak obe strany riadia rôzne hodnoty, v simulácii sa objaví `X`, ale explicitná kontrola by bola lepšia.

Môžeš pridať:

```systemverilog
if (dq_drive && (^dq === 1'bx)) begin
  $error("[SDRAM] DQ contention or unknown on read data bus");
end
```

Ale detekcia inout contention nie je vždy spoľahlivá. Alternatíva je mať samostatný `dq_oe_controller_i` v testbench, ale to už nie je SDRAM pin-compatible model.

---

# 16. `$error` v modeli môže rozbiť negatívne testy

Používaš priamo `$error`. To je dobré pri bežných testoch, ale pri negatívnych testoch môžeš chcieť počítať chyby bez toho, aby simulator hlásil errors.

Odporúčam parameter:

```systemverilog
parameter bit FATAL_ON_ERROR = 1'b0
```

a helper task:

```systemverilog
task automatic sdram_error(input string msg);
  if (FATAL_ON_ERROR)
    $fatal(1, "%s", msg);
  else
    $error("%s", msg);
endtask
```

Prípadne `WARN_ONLY`.

---

# 17. `translate_off` je správne, ale modul aj tak nesmie byť v RTL filelist

Máš:

```systemverilog
// synthesis translate_off
...
// synthesis translate_on
```

To je dobré. Ale stále odporúčam:

```text
- model zaradiť iba do sim filelist,
- nikdy nie do synthesis filelist,
- v IP yaml ho označiť ako simulation-only.
```

V socfw by si mohol pre IP manifest zaviesť:

```yaml
simulation:
  sources:
    - sim/models/sdram_model_pro.sv
```

a nie v `rtl.sources`.

---

# 18. Odporúčané minimálne opravy

Ak nechceš hneď robiť plný SDRAM model, spravil by som aspoň toto:

```text
1. Opraviť CAS latency pipeline off-by-one.
2. Pridať DQM a byte maskovaný WRITE.
3. Pri single-bank PRECHARGE kontrolovať tRAS a tWR.
4. Pridať cmd_mrs decode a warning/error pri READ/WRITE pred MRS.
5. Použiť longint unsigned pre mem key.
6. Ošetriť uninitialized reads cez parameter.
7. Jasne zdokumentovať, že burst behavior zatiaľ nie je modelovaný.
```

---

# 19. Navrhovaná úprava portov

Pre bežný 16-bit SDR SDRAM model:

```systemverilog
module sdram_model_pro #(
  parameter int DATA_WIDTH = 16,
  parameter int ROW_WIDTH  = 13,
  parameter int COL_WIDTH  = 9,
  parameter int BANKS      = 4,
  parameter int BANK_WIDTH = $clog2(BANKS),
  parameter int DQM_WIDTH  = DATA_WIDTH/8,
  ...
)(
  input  wire                    clk,
  input  wire                    rst,
  input  wire                    cke,

  input  wire [ROW_WIDTH-1:0]    addr,
  input  wire [BANK_WIDTH-1:0]   ba,

  input  wire                    ras_n,
  input  wire                    cas_n,
  input  wire                    we_n,
  input  wire                    cs_n,
  input  wire [DQM_WIDTH-1:0]    dqm,

  inout  wire [DATA_WIDTH-1:0]   dq
);
```

Ak tvoj controller zatiaľ nemá `cke` alebo `dqm`, môžeš mať default wrapper alebo pripojiť:

```systemverilog
.cke(1'b1),
.dqm('0)
```

---

# 20. Celkové hodnotenie

## Vhodné na:

```text
- jednoduché single-beat READ/WRITE testy,
- základnú kontrolu bank open/close,
- základné timing violation testy,
- rýchle simulácie bez alokácie veľkej pamäte.
```

## Nevhodné zatiaľ na:

```text
- burst READ/WRITE,
- presný CAS latency test,
- byte maskované zápisy,
- mode register/init sekvenciu,
- auto-precharge presnosť,
- DQM read maskovanie,
- verifikáciu plnohodnotného SDRAM controlleru.
```

---

# Záver

`sdram_model_pro.sv` je dobrý začiatok, ale názov „pro“ je zatiaľ trochu optimistický. Najväčšie chyby, ktoré by som opravil pred použitím v serióznom testbenchi, sú:

```text
1. CAS latency off-by-one.
2. Chýbajúca kontrola tRAS/tWR pri single-bank PRECHARGE.
3. Chýbajúci DQM/byte mask support.
4. Chýbajúci LOAD MODE REGISTER/init check.
5. Okamžitý auto-precharge.
6. `int` adresovanie namiesto `longint unsigned`.
```

Po týchto opravách bude model veľmi užitočný pre socfw SDRAM controller testy.
