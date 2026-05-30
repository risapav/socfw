Analyzoval som aktuálny `eth_test_03.zip`. Stav vývoja je už lepší než predchádzajúce verzie, ale projekt je stále vo fáze **MAC/unit-test bring-up**, nie ešte vo fáze použiteľného UDP echo stacku.

## 1. Aktuálny stav podľa ZIP-u

V archíve je už status dokument:

```text
ETH_TEST_03_STATUS.md
```

Ten pomerne presne vystihuje aktuálny stav:

```text
crc32_eth        PASS
gmii_tx_mac      FAIL
gmii_rx_mac      zatiaľ nespustený / nevalidovaný
eth_header_parser má známe riziko
ipv4_header_parser má stale-validation bug
udp_header_parser chýba
udp_echo_app ešte nie je bezpečne dokončený
ethernet_test_03_top nie je plne zapojený
```

Reálne logy potvrdzujú:

```text
tb_crc32_eth: ALL PASS
tb_gmii_tx_mac: FAIL
```

`tb_crc32_eth` je teraz v dobrom stave:

```text
T1 PASS: CRC32("123456789") = 0xCBF43926
T2 PASS: clear_i resetuje CRC
T3 PASS: crc_next preview sedí
```

To je veľký krok vpred, lebo CRC je základ pre TX MAC.

---

# 2. Najväčší aktuálny problém: `gmii_tx_mac`

`gmii_tx_mac.sv` už má rozumnú FSM:

```systemverilog
ST_IDLE
ST_PREAMBLE
ST_SFD
ST_ETH_HEADER
ST_PAYLOAD
ST_PADDING
ST_FCS
ST_IFG
```

To je správny smer.

Ale test stále padá:

```text
T1 FAIL: IFG=11 want 12
T2 FAIL: payload posunutý o +1
T2 FAIL: FCS nesprávny
```

## 2.1 IFG problém

V teste sa očakáva:

```text
12 idle cyklov po FCS
```

Ale test nameral:

```text
IFG = 11
```

Tu môžu byť dva zdroje problému:

1. `gmii_tx_mac` reálne drží `ST_IFG` iba 11 pozorovateľných cyklov.
2. Testbench zle počíta IFG podľa `tx_busy_o`.

V DUT je:

```systemverilog
assign tx_busy_o = (state_q != ST_IDLE);
assign tx_done_o = (state_q == ST_IFG) && (ifg_cnt_q == 4'(IFG_BYTES - 1));
```

A v teste sa IFG počíta takto:

```systemverilog
while (tx_busy) begin
  ifg_count++;
  @(posedge clk); #1;
end
```

To nepočíta čisto „cykly s `TX_EN=0` po FCS“, ale počíta cykly, kým je `tx_busy=1`. Odporúčam test zmeniť tak, aby IFG meral priamo:

```text
po poslednom cykle gmii_tx_en_o=1
počítaj cykly, kde gmii_tx_en_o=0
kým nezačne ďalší rámec alebo kým tx_done_o
```

Čiže IFG test nemá byť naviazaný na `tx_busy_o`, ale na `gmii_tx_en_o`.

Zároveň v DUT by som zvážil jednoduchšie pravidlo:

```systemverilog
ST_IFG: begin
  if (ifg_cnt_q == IFG_BYTES-1)
    state_d = ST_IDLE;
end
```

a `ifg_cnt_q` inkrementovať iba v `ST_IFG`. To už robíš, takže najprv by som opravil meranie v TB.

---

## 2.2 Payload shift o +1

Test ukazuje:

```text
payload[0] = 0x02, očakávané 0x01
payload[1] = 0x03, očakávané 0x02
...
payload[45] = 0x00, očakávané 0x2E
```

Toto znamená, že prvý payload byte sa stratí alebo sa TB/DUT handshake rozchádza o jeden cyklus.

V `gmii_tx_mac` je v `ST_PAYLOAD`:

```systemverilog
gmii_txd_o    = s_axis_tdata;
s_axis_tready = 1'b1;
if (s_axis_tvalid && s_axis_tlast)
  state_d = ...
```

a počítadlo:

```systemverilog
ST_PAYLOAD: begin
  if (s_axis_tvalid) payload_cnt_q <= payload_cnt_q + 1'b1;
end
```

Toto je citlivé, lebo TX MAC vysiela `s_axis_tdata` kombinačne vždy, keď je `state_q == ST_PAYLOAD`. Pri prechode z `ST_ETH_HEADER` do `ST_PAYLOAD` musí byť `s_axis_tdata` už stabilné na prvý byte. Testbench sa snaží `pl[0]` predpripraviť, ale log ukazuje, že to stále nie je zosúladené.

### Odporúčanie pre RTL

Pre robustný knižničný blok by som nepúšťal `s_axis_tdata` priamo na GMII. Dal by som malý payload register:

```systemverilog
logic [7:0] payload_byte_q;
logic       payload_valid_q;
```

A pravidlo:

```systemverilog
payload_fire = s_axis_tvalid && s_axis_tready;
```

Potom:

```systemverilog
if (payload_fire) begin
  payload_byte_q <= s_axis_tdata;
end
```

A GMII výstup v ďalšom cykle:

```systemverilog
gmii_txd_o = payload_byte_q;
```

Nevýhoda: pridáš jeden cyklus latencie a treba upraviť FSM. Výhoda: handshake bude jednoznačný a testbench nebude závislý od jemného časovania kombinačného `s_axis_tdata`.

### Krátkodobá oprava

Ak chceš zatiaľ ponechať súčasnú architektúru „gapless stream“, potom jasne deklaruj kontrakt:

```text
Počas ST_PAYLOAD musí source držať s_axis_tvalid=1 a s_axis_tdata musí byť pripravené vždy pred príslušnou hranou clk.
```

Potom uprav `tb_gmii_tx_mac.sv`, aby neposúval dáta reaktívne po posedge, ale aby ich predpripravil na negedge pred ďalším handshake cyklom.

Ale dlhodobo odporúčam registrovaný payload výstup alebo vstupnú FIFO.

---

## 2.3 FCS zlyháva ako následok payload shiftu

Pri T2 je FCS:

```text
got  0x0e76305f
want 0xf1b32d3c
```

Keďže payload je posunutý, FCS musí byť zlé. Najprv oprav payload alignment. Až potom má zmysel riešiť CRC v `gmii_tx_mac`.

Samotný `crc32_eth` modul už podľa unit testu funguje.

---

# 3. `gmii_rx_mac` — test existuje, ale Makefile ho zatiaľ zle kompiluje

V `sim/Makefile` cieľ `gmii_rx` je:

```makefile
gmii_rx: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_mac.sv
```

Ale `MAC_COMMON` obsahuje iba:

```makefile
$(RTL)/eth_pkg.sv
$(RTL)/l2/eth_header_builder.sv
$(RTL)/mac/crc32_eth.sv
```

Chýba:

```makefile
$(RTL)/mac/gmii_rx_mac.sv
```

Čiže `tb_gmii_rx_mac` sa nemôže korektne skompilovať, pokiaľ ho nástroj nenájde z predchádzajúceho work adresára. Toto treba opraviť hneď.

Správne:

```makefile
gmii_rx: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_mac.sv
	$(VSIM) tb_gmii_rx_mac | tee $(LOGDIR)/tb_gmii_rx_mac.log
```

A `regression` musí robiť čistý build:

```makefile
all: clean crc32 gmii_tx gmii_rx
```

alebo aspoň samostatný `regression: clean all`.

---

# 4. `gmii_rx_mac.sv` — logika je lepšia, ale stále obmedzená

Aktuálny RX MAC má tieto stavy:

```systemverilog
RX_IDLE
RX_PRE
RX_SFD
RX_DATA
```

Dobré je, že pribudol samostatný `RX_SFD` stav. Cieľ je, aby `0xD5` nepretieklo do streamu.

Ale treba overiť testom. Podľa kódu:

```systemverilog
RX_PRE:
  else if (gmii_rxd_i == 8'hD5) state_d = RX_SFD;

RX_SFD:
  if (!gmii_rx_dv_i) state_d = RX_IDLE;
  else               state_d = RX_DATA;
```

Výstup:

```systemverilog
assign m_axis_tvalid = (state_q == RX_DATA) && dv_q;
assign m_axis_tdata  = rxd_q;
```

Toto by malo správne zahodiť SFD a prvým výstupom by mal byť prvý byte Ethernet headera. Ale treba to potvrdiť `tb_gmii_rx_mac`.

## Obmedzenie

RX MAC stále nerešpektuje `m_axis_tready`.

Komentár to priznáva:

```text
No AXI-Stream backpressure — assumes downstream can always accept data at line rate.
```

To je zatiaľ akceptovateľné pre MAC bring-up, ale potom musí byť za RX MAC FIFO alebo parsery musia garantovať `ready=1`.

Do knižnice by som dal jasný názov alebo parameter:

```text
gmii_rx_mac_no_backpressure
```

alebo priamo vložiť `axis_fifo`.

---

# 5. `eth_header_parser.sv` — už nie je zaseknutý, ale ešte má slabiny

Oproti predchádzajúcej verzii je opravené, že `byte_cnt` sa inkrementuje pri každom header byte:

```systemverilog
byte_cnt <= byte_cnt + 4'd1;
```

Header sa už vypĺňa celý.

Ale stále je tu problém s validáciou headera a stream passthrough.

## 5.1 `drop_o` je odvodené z `header_reg`, ale `header_reg.ethertype[7:0]` sa práve zapisuje

Pri byte 13 robíš:

```systemverilog
header_reg.ethertype[7:0] <= s_axis_tdata;
state_q <= ST_PAYLOAD;
```

V ďalšom cykle už by mala byť hodnota zapísaná. To je pre MAC filter OK, lebo payload začne až ďalším bajtom. Ale ak chceš generovať `hdr_valid_o` pulz presne po hlavičke, bude lepšie mať `header_next_w`.

## 5.2 Chýba explicitný `drop` stav

Teraz:

```systemverilog
assign m_axis_tvalid = s_axis_tvalid && (state_q == ST_PAYLOAD) && !drop_o;
```

Ak je MAC mismatch, parser drží `s_axis_tready = m_axis_tready`. Ak downstream z nejakého dôvodu nie je ready, aj drop frame môže zablokovať vstup.

Pre robustnosť by bolo lepšie mať FSM:

```text
ST_HEADER
ST_PAYLOAD
ST_DROP
```

V `ST_DROP` by parser konzumoval vstup až po `tlast`, ale nič neposielal ďalej.

---

# 6. `ipv4_header_parser.sv` — stale header bug stále existuje

Toto je stále reálny bug.

V stave `ST_HEADER`:

```systemverilog
header_reg <= {header_reg[151:0], s_axis_tdata};
if (byte_cnt == 5'd19) begin
  state_q       <= ST_PAYLOAD;
  hdr_valid_int <= (header_reg[159:152] == 8'h45) && (header_reg[31:0] == local_ip_i);
end
```

V `hdr_valid_int` používaš starý `header_reg`, ešte bez aktuálneho 20. bajtu.

Treba spraviť:

```systemverilog
logic [159:0] header_next_w;

assign header_next_w = {header_reg[151:0], s_axis_tdata};
```

a pri poslednom bajte:

```systemverilog
hdr_valid_int <= (header_next_w[159:152] == 8'h45) &&
                 (header_next_w[79:72]   == eth_pkg::IPV4_PROTO_UDP) &&
                 (header_next_w[31:0]    == local_ip_i);
```

Tiež chýba kontrola:

```text
protocol == UDP
IHL == 5
total_length >= 20
```

Minimálne UDP protocol filter by som doplnil hneď.

---

# 7. `udp_echo_app.sv` — lepší, ale stále nie bezpečný

Teraz už má FSM:

```systemverilog
ST_IDLE
ST_RX
ST_TX_META
ST_TX_PAYLOAD
```

To je posun.

Ale stále má viacero problémov.

## 7.1 Metadata sa nelatchujú

Používaš priamo `rx_meta_i` počas TX:

```systemverilog
if (read_ptr == rx_meta_i.payload_len - 1) state_q <= ST_IDLE;
```

a:

```systemverilog
assign tx_meta_o = '{
  src_mac:     rx_meta_i.dst_mac,
  dst_mac:     rx_meta_i.src_mac,
  ...
};
```

Ak sa `rx_meta_i` zmení po prijatí packetu, výstupná odpoveď sa pokazí.

Treba:

```systemverilog
eth_pkg::udp_packet_meta_t rx_meta_q;
logic [15:0] payload_len_q;
```

a v `ST_IDLE` pri `rx_meta_valid_i`:

```systemverilog
rx_meta_q     <= rx_meta_i;
payload_len_q <= rx_meta_i.payload_len;
```

Potom všade používať `rx_meta_q`.

## 7.2 RX zápis ignoruje `s_axis_tready`

V `ST_RX`:

```systemverilog
if (s_axis_tvalid) begin
  mem[write_ptr] <= s_axis_tdata;
```

Správne má byť:

```systemverilog
if (s_axis_tvalid && s_axis_tready) begin
```

Teraz je `s_axis_tready = (state_q == ST_RX)`, takže to v jednoduchom prípade vyjde rovnako, ale z hľadiska stream kontraktu máš používať handshake.

## 7.3 `m_axis_tlast` má byť viazané na valid

Teraz:

```systemverilog
assign m_axis_tlast  = (read_ptr == rx_meta_i.payload_len - 1);
```

Lepšie:

```systemverilog
assign m_axis_tlast = m_axis_tvalid && (read_ptr == payload_len_q - 1);
```

## 7.4 Chýba overflow ochrana

Ak príde payload väčší než `MAX_PAYLOAD_BYTES`, zápis ide mimo buffer.

Treba error/drop:

```systemverilog
if (write_ptr == MAX_PAYLOAD_BYTES-1 && !s_axis_tlast)
  overflow_q <= 1'b1;
```

---

# 8. `ethernet_test_03_top.sv` ešte nie je použiteľný

Top má už porty, ale nie je hotový.

Najväčšie problémy:

## 8.1 Output port pripojený na konštantu

Inštancia RX MAC:

```systemverilog
.m_axis_tuser(1'b0)
```

Ale `m_axis_tuser` je output z `gmii_rx_mac`. Výstup nesmieš pripájať na konštantu.

Treba signál:

```systemverilog
logic rx_axis_tuser;
```

a:

```systemverilog
.m_axis_tuser(rx_axis_tuser)
```

## 8.2 Chýba `eth_debug_leds.sv`

Top inštancuje:

```systemverilog
eth_debug_leds u_leds (...)
```

ale súbor v ZIP-e nie je.

Buď ho doplň, alebo zatiaľ nahraď jednoduchým assign:

```systemverilog
assign led_o = {eth_txen_o, 1'b0, 1'b0, eth_rxdv_i, 1'b1, sys_clk_i_div};
```

## 8.3 TX vetva nie je zapojená

Výstupy:

```systemverilog
eth_txd_o
eth_txen_o
eth_txer_o
```

nemajú reálnu cestu z UDP echo aplikácie do `gmii_tx_mac`.

Chýbajú:

```text
udp_header_parser
udp_header_builder
ipv4_header_builder
TX metadata pre gmii_tx_mac
TX stream payload
```

Preto `ethernet_test_03_top` ešte nemôže fungovať ako UDP echo systém.

---

# 9. Simulačný framework

Makefile má zatiaľ ciele:

```text
crc32
gmii_tx
gmii_rx
```

To je správne pre aktuálnu fázu. Ale treba opraviť:

```text
gmii_rx cieľ nekompiluje gmii_rx_mac.sv
```

A pridať:

```makefile
regression: clean all
```

Aby si sa nespoliehal na starý `work`.

Odporúčané:

```makefile
.PHONY: regression
regression: clean all
```

---

# 10. Aktuálny stav vývoja podľa vrstiev

## Vrstva 0 — package/helpery

```text
eth_pkg.sv      použiteľné
tb_eth_pkg.sv   použiteľné
```

Stav: dobrý.

## Vrstva 1 — CRC

```text
crc32_eth.sv    PASS
```

Stav: uzavreté pre prvú fázu.

## Vrstva 2 — GMII TX

```text
gmii_tx_mac.sv  implementovaný, ale tb FAIL
```

Stav: hlavný aktuálny blocker.

## Vrstva 3 — GMII RX

```text
gmii_rx_mac.sv  implementovaný, ale tb zatiaľ nespustený kvôli Makefile
```

Stav: treba spustiť a validovať.

## Vrstva 4 — Ethernet parser

```text
eth_header_builder.sv  OK, ale treba unit test
eth_header_parser.sv   čiastočne OK, chýba robustný drop state
```

Stav: ďalšia priorita po MAC.

## Vrstva 5 — IPv4

```text
ipv4_checksum.sv       dobrý základ
ipv4_header_parser.sv  stale header bug
```

Stav: nie je pripravené.

## Vrstva 6 — UDP/app

```text
udp_header_parser.sv   chýba
udp_echo_app.sv        čiastočný, treba meta latch a handshake cleanup
```

Stav: ešte nie je pripravené na integráciu.

## Vrstva 7 — top

```text
ethernet_test_03_top.sv skeleton s RX vetvou, TX vetva chýba
```

Stav: neintegrovať, kým MAC/L2/L3/L4 neprejdú.

---

# 11. Odporúčaný ďalší postup

## Krok 1 — opraviť Makefile

Hneď doplniť `gmii_rx_mac.sv` do `gmii_rx` cieľa:

```makefile
gmii_rx: $(LOGDIR)
	$(VLOG) $(MAC_COMMON) \
	        $(RTL)/mac/gmii_rx_mac.sv \
	        $(TB_COMMON) \
	        mac/tb_gmii_rx_mac.sv
	$(VSIM) tb_gmii_rx_mac | tee $(LOGDIR)/tb_gmii_rx_mac.log
```

A pridať:

```makefile
regression: clean all
```

## Krok 2 — rozhodnúť payload handshake v `gmii_tx_mac`

Máš dve možnosti:

### Variant A — gapless stream

Zdokumentovať:

```text
s_axis_tvalid musí byť počas payloadu bez bublín.
```

Opraviť testbench tak, aby dáta menil v správnej fáze.

### Variant B — robustný stream

Doplniť payload register/FIFO a podporovať `valid` pauzy.

Pre knižnicu odporúčam Variant B, ale pre rýchly postup môžeš najprv uzavrieť Variant A.

## Krok 3 — opraviť IFG test

IFG merať cez `gmii_tx_en_o == 0`, nie cez `tx_busy_o`.

## Krok 4 — spustiť a opraviť `tb_gmii_rx_mac`

Očakávané testy:

```text
SFD sa neobjaví vo výstupe
prvý byte je dst_mac[47:40]
tlast príde na poslednom bajte
počet bajtov sedí
```

## Krok 5 — pridať unit testy pre L2/L3/app

V poradí:

```text
tb_eth_header_builder
tb_eth_header_parser
tb_ipv4_checksum
tb_ipv4_header_parser
tb_udp_echo_app
```

## Krok 6 — až potom integračné testy

Najprv:

```text
stream -> gmii_tx_mac -> gmii_rx_mac -> stream
```

Potom:

```text
GMII RX -> gmii_rx_mac -> eth_header_parser -> gmii_tx_mac -> GMII TX
```

A až na konci:

```text
UDP full path
```

---

## Krátky verdikt

Aktuálny vývoj je v správnom smere. Oproti prvej kostre máš už:

```text
+ funkčný CRC modul
+ rozpracovaný GMII TX MAC
+ rozpracovaný GMII RX MAC
+ použiteľný status dokument
+ prvé reálne unit testy
```

Ale najbližšie sa treba zdržať integrácie topu. Momentálne je najdôležitejšie uzavrieť:

```text
1. gmii_tx_mac
2. gmii_rx_mac
3. eth_header_parser
```

Až keď tieto tri vrstvy prejdú testami, má zmysel pokračovať na IPv4/UDP a full-path echo.
