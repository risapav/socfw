Analyzoval som 4 súbory alternatívneho projektu:

* `xfcp_rx_parser.sv`
* `xfcp_axi_engine.sv`
* `xfcp_fabric_endpoint.sv`
* `xfcp_tx_packetizer.sv`

Nižšie je porovnanie s naším aktuálnym smerom XFCP projektu a odporúčanie, čo z toho prevziať.

---

## 1. Celkový verdikt

Alternatívny projekt je **ambicióznejší a viac pipeline-orientovaný** než náš doterajší návrh. Obsahuje kompletný endpoint:

```text
AXI-Stream RX
   ↓
xfcp_rx_parser
   ↓
request header FIFO + write data FIFO
   ↓
xfcp_fabric_endpoint
   ↓
N × xfcp_axi_engine
   ↓
order FIFO + response arbiter
   ↓
xfcp_tx_packetizer
   ↓
AXI-Stream TX
```

Silná stránka alternatívneho návrhu je, že už rieši:

* multi-slave AXI-Lite fabric,
* address decode,
* order FIFO pre in-order odpovede,
* oddelený parser / AXI engine / packetizer,
* backpressure cez FIFO,
* niektoré známe deadlocky,
* veľa simulačných výpisov a assertions.

Ale aktuálny stav by som **neprevzal priamo**. Našiel som viacero vážnych integračných rizík, z ktorých niektoré môžu spôsobiť deadlock alebo nesprávne routovanie dát.

---

## 2. Porovnanie s naším projektom

| Oblasť                   | Náš aktuálny smer                                                            | Alternatívny projekt                                          | Hodnotenie                                         |
| ------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------- |
| Integrácia do frameworku | Chceme IP modul použiteľný cez `project.yaml`, s AXI-Lite/AXI-Stream väzbami | Má čisté SV moduly, ale ešte nie je zabalený ako framework IP | Alternatívu treba obaliť do nášho IP modelu        |
| Modularita               | Smerujeme k registrovým IP blokom + generátor topológie                      | Dobrá vnútorná modularita: parser, fabric, engine, packetizer | Použiteľné ako základ                              |
| AXI-Lite                 | Chceme štandardizovaný bus binding                                           | Má `axi4lite_if.master m_axil[NUM_SLAVES]`                    | Dobré, ale treba zosúladiť s naším `socfw` štýlom  |
| AXI-Stream               | Potrebujeme jasné RX/TX rozhranie                                            | Používa `axi4s_if.slave/master`                               | Dobré, treba pridať do YAML/IP definície           |
| Multi-device fabric      | V našom projekte ešte skôr návrhová časť                                     | Alternatíva má `NUM_SLAVES`, base/mask dekódovanie            | Toto je najväčší prínos alternatívy                |
| Testovanie               | Chceme navrhnúť testy modulov                                                | Alternatíva má assertions, ale nie kompletný testbench        | Assertions ponechať, doplniť TB                    |
| Robustnosť protokolu     | Ešte definujeme                                                              | Alternatíva má DROP, watchdog, SOP recovery                   | Dobré, ale TLAST validácia je neúplná              |
| Stav pripravenosti       | Náš projekt je frameworkovo čistenejší                                       | Alternatíva je funkčne bohatšia, ale riziková                 | Najlepšie je prevziať idey, nie celý kód bez úprav |

---

## 3. Najväčšie pozitíva alternatívneho projektu

### 3.1 Dobrá top-level architektúra

`xfcp_fabric_endpoint` je dobrý koncept. Jeden XFCP stream vie obslúžiť viac AXI-Lite slave zariadení podľa adresy:

```systemverilog
parameter int NUM_SLAVES = 4;
parameter logic [AXI_ADDR_WIDTH-1:0] SLAVE_BASE [NUM_SLAVES];
parameter logic [AXI_ADDR_WIDTH-1:0] SLAVE_MASK [NUM_SLAVES];
```

Toto sa veľmi hodí do nášho frameworku. V YAML by to mohlo vyzerať približne takto:

```yaml
modules:
  - instance: xfcp0
    type: xfcp_fabric_endpoint
    params:
      NUM_SLAVES: 4
      AXI_ADDR_WIDTH: 32
      AXI_DATA_WIDTH: 32
      SLAVE_BASE:
        - 0x00000000
        - 0x00010000
        - 0x00020000
        - 0x00030000
      SLAVE_MASK:
        - 0xFFFF0000
        - 0xFFFF0000
        - 0xFFFF0000
        - 0xFFFF0000
    buses:
      s_axis: xfcp_rx_stream
      m_axis: xfcp_tx_stream
      m_axil:
        - ctrl0.s_axil
        - gpio0.s_axil
        - timer0.s_axil
        - user0.s_axil
```

Toto je presne smer, ktorý by sa dal zaradiť do `examples/xfcp_test`.

---

### 3.2 Oddelenie parsera, engine a packetizera

Toto je dobré:

```text
xfcp_rx_parser       = protokolový vstup
xfcp_axi_engine      = AXI-Lite transakcie
xfcp_tx_packetizer   = protokolový výstup
xfcp_fabric_endpoint = routing + ordering
```

Pre náš projekt je to lepšie než jeden veľký monolitický modul.

---

### 3.3 Order FIFO je správny smer

Alternatívny projekt používa `order_fifo`, aby sa odpovede vracali v rovnakom poradí ako requesty.

To je dôležité, ak viac AXI slave zariadení beží paralelne a jedno odpovie skôr než druhé.

Toto by som určite prevzal ako koncept.

---

### 3.4 Parser má dobré robustnostné prvky

`xfcp_rx_parser` obsahuje:

* SOP detekciu,
* SOP recovery,
* DROP stav,
* watchdog na príliš dlhý paket,
* header FIFO,
* payload FIFO,
* assertions.

To je dobrý základ pre FPGA verifikáciu.

---

## 4. Kritické problémy, ktoré by som pred prevzatím opravil

### Problém A: `xfcp_axi_engine` má chybný READ pipelining

V `ST_RD_WAIT` sa engine pokúša poslať AR adresu pre ďalšie slovo ešte počas čakania na aktuálne RDATA:

```systemverilog
if (m_axil.RVALID) begin
  state_n = ST_NEXT;

  if (rem_q > COUNT_WIDTH'(ADDR_INC)) begin
    m_axil.ARVALID = 1'b1;
    m_axil.ARADDR  = addr_q + AXI_ADDR_WIDTH'(ADDR_INC);
  end
end
```

Potom v `ST_NEXT` kontroluje:

```systemverilog
if (m_axil.ARVALID && m_axil.ARREADY)
  state_n = ST_RD_WAIT;
else
  state_n = ST_RD_ADDR;
```

Lenže v `ST_NEXT` už `m_axil.ARVALID` nie je informácia z predchádzajúceho cyklu. V kombinačnej logike je defaultne znova `0`.

Dôsledok:

* ak sa pipeline AR handshake naozaj stane,
* engine to v ďalšom stave nevie,
* prejde do `ST_RD_ADDR`,
* a môže poslať rovnakú AR adresu ešte raz.

Toto je vážna chyba.

Odporúčaná oprava:

```systemverilog
logic rd_pipe_ar_accepted_q;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)
    rd_pipe_ar_accepted_q <= 1'b0;
  else begin
    rd_pipe_ar_accepted_q <= 1'b0;

    if (state_q == ST_RD_WAIT &&
        m_axil.RVALID &&
        rem_q > COUNT_WIDTH'(ADDR_INC) &&
        m_axil.ARREADY)
      rd_pipe_ar_accepted_q <= 1'b1;
  end
end
```

A v `ST_NEXT` rozhodovať podľa registrovaného flagu, nie podľa aktuálneho `ARVALID`.

Jednoduchšia bezpečná verzia: **pipelining zatiaľ vypnúť** a robiť READ sekvenčne:

```text
RD_ADDR → RD_WAIT → NEXT → RD_ADDR → ...
```

Pre prvú integráciu do nášho frameworku by som zvolil radšej bezpečnú sekvenčnú verziu.

---

### Problém B: read FIFO môže stratiť dáta

V `xfcp_axi_engine` je read FIFO zapisované takto:

```systemverilog
.w_valid(m_axil.RVALID && m_axil.RREADY),
.w_ready()
```

Ale `m_axil.RREADY` je stále `1`:

```systemverilog
m_axil.RREADY = 1'b1;
```

To znamená, že engine prijíma RDATA aj vtedy, keď interný read FIFO už nemusí mať miesto. `w_ready` z FIFO sa ignoruje.

Bezpečnejšie má byť:

```systemverilog
logic rfifo_w_ready;

assign m_axil.RREADY = rfifo_w_ready;

xfcp_fifo i_read_buffer (
  ...
  .w_valid(m_axil.RVALID && m_axil.RREADY),
  .w_ready(rfifo_w_ready),
  ...
);
```

Inak pri dlhšom READ alebo zablokovanom packetizeri môže dôjsť k strate dát.

---

### Problém C: `fabric_endpoint` čaká s packetizerom až na `eng_done`, ale packetizer potrebuje `resp_done_i` synchronizovaný s posledným slovom

Toto je podľa mňa najväčší architektonický problém.

`xfcp_tx_packetizer` ukončuje READ payload vtedy, keď pri poslednom byte slova vidí:

```systemverilog
done_flag = done_latch_q || resp_done_i;
```

Lenže `xfcp_fabric_endpoint` spúšťa packetizer až keď engine už skončil:

```systemverilog
if (eng_done_rdy[ofifo_rdata.sel]) begin
  ofifo_rready     = 1'b1;
  resp_start_pulse = 1'b1;
  arb_n            = ARB_WAIT_PKT;
end
```

To znamená:

1. engine dokončí READ,
2. `eng_resp_done` je len 1-taktový pulz,
3. arbiter až potom spustí packetizer,
4. packetizer už ten pulz nemusí nikdy vidieť,
5. pri READ môže zostať visieť v `ST_PAYLOAD`.

Toto môže spôsobiť deadlock.

Sú dve možné opravy:

#### Varianta 1 — pridať `last` bit do read FIFO

Namiesto samostatného `resp_done_i` by engine ukladal do FIFO:

```systemverilog
typedef struct packed {
  logic [AXI_DATA_WIDTH-1:0] data;
  logic                     last;
} read_word_t;
```

Packetizer potom vie, ktoré slovo je posledné. Toto je najrobustnejšie riešenie.

#### Varianta 2 — spúšťať packetizer skôr

Pri READ by arbiter nemal čakať na `eng_done`, ale môže spustiť packetizer hneď, keď je request na čele order FIFO a packetizer je voľný. Packetizer potom po headeri čaká v `ST_PAYLOAD`, kým prídu dáta.

Toto viac zodpovedá súčasnému návrhu `resp_done_i`, ale je zložitejšie pri in-order riadení.

Pre náš projekt odporúčam variantu 1: **read FIFO s `last` príznakom**.

---

### Problém D: nulový WRITE môže deadlocknúť

V parseri:

```systemverilog
if (dec_opcode == XFCP_OP_WRITE && dec_words != 0) begin
  state_n = S_PAYLOAD;
end else begin
  // READ/ID: pushni header a choď do IDLE
end
```

Ak príde `WRITE` s `count = 0`, parser ho pošle ako header bez payloadu.

Ale v `xfcp_axi_engine` platí:

```systemverilog
if (req_hdr.opcode == XFCP_OP_WRITE)
  req_ready = (state_q == ST_IDLE) && packetizer_idle_i && wfifo_valid;
```

Pre nulový WRITE nebude `wfifo_valid`, takže `req_ready` nikdy nepríde.

Riešenie:

* buď zakázať `WRITE count=0` v parseri,
* alebo ho v engine spracovať ako okamžitý `RESP_WRITE` bez AXI transakcie.

Ja by som odporúčal jednoduché pravidlo:

```text
WRITE musí mať count > 0 a count % 4 == 0.
READ môže mať count > 0 a count % 4 == 0.
ID môže mať count = 0.
```

---

### Problém E: neúplná TLAST validácia

Parser deteguje TLAST uprostred payloadu:

```systemverilog
if (state_q == S_PAYLOAD && axis_fire &&
    s_axis_tlast && bytes_left_q != 1)
  go_drop = 1'b1;
```

Ale nekontroluje opačný prípad: posledný payload byte bez `TLAST`.

Teda WRITE paket s chýbajúcim TLAST môže byť akceptovaný.

Doplniť:

```systemverilog
if (state_q == S_PAYLOAD &&
    axis_fire &&
    bytes_left_q == 1 &&
    !s_axis_tlast)
  go_drop = 1'b1;
```

Podobne pri READ/ID bez payloadu treba jasne rozhodnúť, či TLAST musí byť na poslednom header byte. Ak áno, treba to validovať.

---

### Problém F: invalid address + WRITE payload môže byť zle routovaný

Vo `fabric_endpoint` je:

```systemverilog
assign wdata_sel   = req_valid ? dec_sel : slave_sel_q;
assign wdata_valid = wdata_valid_raw;
assign wdata_ready = eng_wdata_ready[wdata_sel];
```

Ak príde WRITE na neplatnú adresu:

* `dec_valid = 0`,
* `req_ready = 0`,
* header ostane visieť,
* ale payload dáta môžu stále tiecť cez `wdata_valid_raw`,
* `dec_sel` defaultne ukazuje na slave 0,
* payload môže omylom skončiť v engine 0.

Toto je kritické.

Treba zaviesť explicitný stav „aktívny write target je platný“:

```systemverilog
logic active_write_valid_q;
logic [SEL_W-1:0] active_write_sel_q;
```

A payload púšťať do enginu iba vtedy, keď je cieľ platný a header bol akceptovaný alebo bezpečne latched.

Minimálna ochrana:

```systemverilog
assign wdata_valid = wdata_valid_raw && dec_valid;
assign wdata_ready = dec_valid ? eng_wdata_ready[wdata_sel] : 1'b0;
```

Ale lepšia oprava je aktívny write context.

---

### Problém G: timeout v engine zablokuje order FIFO

`xfcp_axi_engine` pri timeout nastaví:

```systemverilog
error_timeout <= 1'b1;
state_n = ST_DONE;
```

Ale:

```systemverilog
assign resp_done = ... && !error_timeout;
```

Teda pri timeoute nevznikne `resp_done`.

Vo fabricu ale už existuje záznam v `order_fifo`, ktorý čaká na dokončenie enginu. Výsledok môže byť zablokovaný response arbiter.

Treba rozhodnúť, čo má protokol robiť pri AXI timeoute:

* poslať error response,
* dropnúť request a popnúť order FIFO,
* alebo resetnúť celý endpoint.

Aktuálny stav je nebezpečný, lebo timeout nerobí čisté zotavenie.

---

## 5. Čo by som z alternatívneho projektu prevzal

Prevzal by som tieto časti:

1. **Rozdelenie na parser / engine / packetizer / fabric endpoint.**
2. **`NUM_SLAVES` + `SLAVE_BASE` + `SLAVE_MASK` address decode.**
3. **Order FIFO pre in-order responses.**
4. **SOP recovery, DROP state, watchdog v parseri.**
5. **Dual-slot TX packetizer**, ale až po vyriešení `last` mechanizmu.
6. **Simulačné assertions**, ale rozšíril by som ich.

Neprevzal by som zatiaľ bez úprav:

* READ pipelining v `xfcp_axi_engine`,
* súčasný `resp_done_i` mechanizmus,
* súčasné routovanie WRITE payloadu,
* timeout správanie,
* nulový WRITE handling.

---

## 6. Odporúčaný smer pre náš projekt

Navrhujem nesnažiť sa tento alternatívny projekt priamo začleniť celý. Lepší postup:

### Krok 1 — spraviť „bezpečnú v1“ architektúru

Pre prvú verziu v našom frameworku:

```text
1 request at a time per endpoint
1 AXI-Lite transaction sequence at a time
bez READ pipeliningu
read FIFO obsahuje data + last
write count=0 zakázaný
strict TLAST validácia
```

Tým sa výrazne zníži riziko deadlockov.

---

### Krok 2 — upraviť protokolové pravidlá

Navrhujem tieto pravidlá:

```text
Request packet:
  SOP_REQ
  OPCODE
  COUNT[15:8]
  COUNT[7:0]
  ADDR[31:24]
  ADDR[23:16]
  ADDR[15:8]
  ADDR[7:0]
  PAYLOAD only for WRITE
  TLAST on final byte

Valid:
  ID:
    count = 0
    no payload
    TLAST on ADDR[7:0]

  READ:
    count > 0
    count % 4 == 0
    no payload
    TLAST on ADDR[7:0]

  WRITE:
    count > 0
    count % 4 == 0
    payload length = count
    TLAST on final payload byte
```

---

### Krok 3 — zmeniť read path na `data + last`

V engine:

```systemverilog
typedef struct packed {
  logic [AXI_DATA_WIDTH-1:0] data;
  logic                     last;
} xfcp_read_word_t;
```

Packetizer potom nepotrebuje krehký `resp_done_i` pulz.

---

### Krok 4 — upraviť IP definíciu pre framework

Do nášho `ip/xfcp_fabric_endpoint` by som dal:

```yaml
type: xfcp_fabric_endpoint
bus_interfaces:
  s_axis:
    type: axi_stream
    mode: slave
    data_width: 8

  m_axis:
    type: axi_stream
    mode: master
    data_width: 8

  m_axil:
    type: axi_lite
    mode: master
    count_param: NUM_SLAVES
```

A v príklade `examples/xfcp_test` mať aspoň:

```text
xfcp_fabric_endpoint
  ├── axil_gpio
  ├── axil_timer
  ├── axil_regs
  └── axil_dummy_ram
```

---

## 7. Testy, ktoré by som spravil ako prvé

### Unit test: `xfcp_rx_parser`

Testy:

1. valid ID packet,
2. valid READ packet,
3. valid WRITE 1 word,
4. valid WRITE 4 words,
5. invalid opcode,
6. count not aligned,
7. WRITE count=0,
8. missing TLAST,
9. early TLAST,
10. SOP recovery uprostred poškodeného paketu.

---

### Unit test: `xfcp_axi_engine`

Testy:

1. single WRITE,
2. single READ,
3. multi-word WRITE,
4. multi-word READ bez pipeliningu,
5. AXI slave backpressure na AW/W/B/AR/R,
6. read FIFO full,
7. write FIFO empty,
8. timeout,
9. BRESP/RRESP error.

---

### Integration test: `xfcp_fabric_endpoint`

Testy:

1. READ slave0,
2. READ slave1,
3. WRITE slave0,
4. WRITE slave1,
5. invalid address,
6. two requests to different slaves,
7. response ordering,
8. packetizer busy,
9. AXI slave slow response,
10. long READ payload.

---

## 8. Moje odporúčanie

Alternatívny projekt je veľmi dobrý ako **architektonická inšpirácia**, ale nie ako hotový kód na okamžité prevzatie.

Najväčšia hodnota:

```text
xfcp_fabric_endpoint + order_fifo + multi-slave AXI-Lite routing
```

Najväčšie riziko:

```text
resp_done / packetizer synchronizácia pri READ odpovediach
```

Pre náš projekt by som navrhol tento postup:

1. Prevziať topológiu modulov.
2. Zjednodušiť `xfcp_axi_engine` — dočasne bez READ pipeliningu.
3. Upraviť read FIFO na `data + last`.
4. Sprísniť parser pravidlá pre `COUNT` a `TLAST`.
5. Opraviť WRITE payload routing vo fabricu.
6. Až potom spraviť `ip.yaml` / `project.yaml` integráciu do nášho frameworku.
7. Nakoniec pridať `examples/xfcp_test`.

Tým získame výhody alternatívneho projektu, ale bez najrizikovejších deadlockov.
