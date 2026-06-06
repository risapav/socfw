Skontroloval som `eth_test_04(2).zip`.

```text
eth_test_04(2).zip
SHA-256: 7cd41fbdd61ff389f9cc661ebcf9867ba67576a1fbd1dc53a351b77e9d998d4a
SHA-1:   3d92713e44a92e0c966f3ab61014c77ae82d5f29
MD5:     aa85d7ba90ed2a2b98899a51ce22b4c3
```

## 1. Pôvodná chyba `genvar` je opravená

V aktuálnom ZIP-e už máš:

```systemverilog
genvar g_xor_idx;

generate
  ...
  for (g_xor_idx = 0; g_xor_idx < OUT_W; g_xor_idx = g_xor_idx + 1) begin : g_xor
    assign lfsr_out[g_xor_idx] = ^(lfsr_in & LFSR_MASK[g_xor_idx]);
  end
  ...
endgenerate
```

To je správne. Pôvodná chyba bola spôsobená inline tvarom `for (genvar n = ...)`, ktorý Quartus v tomto kontexte nezobral. V priloženom súbore je už `genvar` deklarovaný samostatne, takže táto časť je vyriešená. V staršom priloženom texte bola problematická práve generate slučka okolo `g_xor`.

Aktuálny hash `taxi_lfsr.sv` v ZIP-e:

```text
rtl/eth/mac/taxi_lfsr.sv
SHA-256: 3f8a7901eace6236ddf8922243b1fb36a8b9c5292c7c49888c6a57791849c7bd
```

---

## 2. Quartus build je úspešný

Reporty v ZIP-e hovoria:

```text
Flow Status: Successful
Quartus Prime Version: 25.1std.0 Build 1129
Device: EP4CE55F23C8
```

Resource usage:

```text
Logic elements: 1,735 / 55,856
Registers:      1,380
Memory bits:    18,432
PLLs:           1 / 4
```

Timing:

```text
Slow 85C setup:
ETH_RXC     +1.112 ns
ETH_TX_CLK  +1.646 ns
SYS_CLK     +5.328 ns

Slow 85C hold:
ETH_RXC     +0.429 ns
ETH_TX_CLK  +0.449 ns
SYS_CLK     +0.461 ns
```

Teda z pohľadu Quartusu:

```text
syntéza OK
fitter OK
assembler OK
STA OK
```

---

# 3. Vážny funkčný problém: RX FSM stále preskočí prvý RXDV bajt

Toto je teraz najdôležitejšie.

V `ETH_TEST_04_STATUS.md` máš správne uvedené:

```text
RTL8211EG RXDV sa asertuje od SFD (0xD5), nie od preamble
gmii_rx_mac musí akceptovať RXDV && rxd==0xD5 priamo z RX_IDLE stavu
```

Ale aktuálny `eth_rx_mac.sv` to ešte nerobí správne.

Aktuálny kód:

```systemverilog
ST_IDLE: begin
  win_cnt_q   <= 3'd0;
  rx_er_acc_q <= 1'b0;
  if (rxdv_q)
    state_q <= ST_PREAMBLE;
end
```

Problém:

```text
cyklus N:
  rxdv_q = 1
  rxd_q  = D5
  stav   = ST_IDLE

výsledok:
  FSM iba prejde do ST_PREAMBLE
  bajt D5 sa nespracuje

cyklus N+1:
  stav = ST_PREAMBLE
  rxd_q = prvý byte DST_MAC
```

Ak DST je unicast `00`, alebo broadcast `FF`, tak v `ST_PREAMBLE` nie je ani `55`, ani `D5`, takže frame sa zahodí.

To presne sedí s doterajším HW správaním:

```text
RXDV activity existuje,
ale loopback timeout,
pretože RX MAC neprejde do header parsing fázy.
```

## Oprava RX FSM

V `ST_IDLE` musíš spracovať prvý `RXDV` byte priamo:

```systemverilog
ST_IDLE: begin
  win_cnt_q   <= 3'd0;
  rx_er_acc_q <= 1'b0;

  // RTL8211EG/GMII commonly asserts RXDV starting at the SFD byte
  // (0xD5), not during the preamble. Therefore the first RXDV byte
  // must be consumed here; otherwise SFD is skipped and the first
  // destination-MAC byte is interpreted as preamble/SFD.
  if (rxdv_q) begin
    if (rxd_q == 8'hD5) begin
      state_q     <= ST_HEADER;
      hdr_cnt_q   <= 4'd0;
      crc_state_q <= 32'hFFFF_FFFF;
      pkt_bcast_q <= 1'b1;
      pkt_mcast_q <= 1'b0;
      mac_match_q <= 1'b0;
      rx_er_acc_q <= rxer_q;
      win_cnt_q   <= 3'd0;
      dst_mac_q   <= '0;
      src_mac_q   <= '0;
      eth_type_q  <= '0;
    end else if (rxd_q == 8'h55) begin
      state_q     <= ST_PREAMBLE;
      rx_er_acc_q <= rxer_q;
    end else begin
      // Bad first byte. Stay in IDLE and wait for the next frame.
      rx_drop_q <= rx_drop_q + 16'd1;
    end
  end
end
```

Pripravil som upravený súbor:

[Download `eth_rx_mac_fix1.sv`](sandbox:/mnt/data/eth_rx_mac_fix1.sv)

```text
SHA-256: c0634c94b82725d476bedad57727c49f1191fb0e929dfccad6c7a44113e15e3e
```

Toto by som aplikoval ako prvý patch.

---

# 4. TX MAC je kompilačne OK, ale má warning kvôli `fire_w`

Quartus hlási:

```text
Warning (10036): object "fire_w" assigned a value but never read
```

V `eth_tx_mac.sv` máš:

```systemverilog
logic fire_w;
assign fire_w = s_axis_tvalid_i && s_axis_tready_o;
```

ale v `ST_PAYLOAD` používaš:

```systemverilog
if (!s_axis_tvalid_i) begin
```

Keď už si zaviedol AXI-S handshake, použi ho aj v FSM:

```systemverilog
ST_PAYLOAD: begin
  if (!fire_w) begin
    // Underflow: abort frame
    ...
  end else begin
    ...
  end
end
```

Funkčne je to teraz skoro rovnaké, pretože:

```systemverilog
assign s_axis_tready_o = (state_q == ST_PAYLOAD);
```

ale štýlovo a do budúcnosti je správne používať `fire_w`.

Pripravil som aj túto drobnú úpravu:

[Download `eth_tx_mac_fix1.sv`](sandbox:/mnt/data/eth_tx_mac_fix1.sv)

```text
SHA-256: 2e25bf3ea83eb785fc5dc9772387fd9f78bc50e361a29dac214861eba927896d
```

---

# 5. Ostatné Quartus warnings

## Neškodné alebo očakávané

```text
ETH_MDC stuck at GND
UART_TX stuck at VCC
ONB_BTN[0..2] do not drive logic
```

Toto je v tomto teste očakávané.

## Upratať

```text
UART_RX assigned to location, but does not exist in design
```

Odporúčam odstrániť `UART_RX` z board/qsf generovania pre tento example, ak UART RX nie je v top-e.

## Reálne užitočný warning

```text
overflow_sticky_q assigned but never read
```

V top-e ho síce vytváraš:

```systemverilog
logic overflow_sticky_q;
```

ale nikam ho nevyvádzaš. Daj ho aspoň na debug bit, inak nevieš, či payload FIFO niekedy preteká.

Napríklad:

```systemverilog
assign dbg_ctrl_o = {
  overflow_sticky_q,
  rx_stat_overflow_w,
  tx_stat_underflow_w[0],
  echo_stat_discard_w[0],
  echo_stat_echo_w[0],
  rx_stat_drop_w[0],
  tx_stat_frames_w[0],
  rx_stat_frames_w[0]
};
```

Terajšie:

```systemverilog
assign dbg_ctrl_o = tx_stat_frames_w[7:0];
```

je menej diagnostické.

---

# 6. `pkt_mcast_q` je nepoužitý

Quartus hlási:

```text
object "pkt_mcast_q" assigned a value but never read
```

Buď ho odstráň, alebo doplň parameter:

```systemverilog
parameter bit ACCEPT_MULTICAST = 1'b0
```

a potom:

```systemverilog
mac_match_q <= (dst_mac_q == LOCAL_MAC) ||
               (ACCEPT_BROADCAST && pkt_bcast_q) ||
               (ACCEPT_MULTICAST && pkt_mcast_q);
```

Pre aktuálny test ho pokojne odstráň, ale pre budúci IPv4/ARP/multicast sa bude hodiť.

---

# 7. Dôležitá poznámka k RX architektúre

Komentár v `eth_rx_mac.sv` hovorí, že výstup je payload-only, ale implementácia je stále **cut-through s oneskorením 4 bajty**, nie store-and-forward.

To znamená:

```text
payload bajty idú do FIFO ešte predtým, než je známe fcs_ok
metadata s fcs_ok príde až na konci frame
echo_app potom rozhodne, či payload z FIFO forwardne alebo zahodí
```

Toto je použiteľné, ale musí platiť poradie:

```text
payload FIFO obsahuje payload celého frame
meta FIFO dostane záznam až po tlast
echo_app čaká najprv na meta
a až potom číta payload FIFO
```

Aktuálne to tak vyzerá, takže koncept je v poriadku.

Riziko zostáva iba pri preplnení meta FIFO:

```text
ak meta_valid_q ešte drží starý záznam a skončí ďalší frame,
payload už môže byť vo FIFO, ale nová meta sa nemusí uložiť
```

Pri `META_FIFO DEPTH=8` to pri tvojich testoch asi nenastane, ale diagnosticky by som pridal `meta_overflow_sticky`.

---

# 8. Najdôležitejší ďalší HW test po RX fix-e

Po aplikovaní `eth_rx_mac_fix1.sv` očakávam, že RX MAC konečne začne rozpoznávať SFD.

Spusti:

```bash
make compile
make program
sleep 5 && ./diag.sh 2>&1
make loopback-test
```

Ak stále failne, spusti:

```bash
make loopback-sniff
```

a sleduj:

```text
LED[4] RX activity
LED[5] TX activity
dbg_mac_data_o = rx_stat_frames_w[7:0]
dbg_ctrl_o     = tx_stat_frames_w[7:0]
```

Po RX fix-e by sa malo zmeniť minimálne:

```text
rx_stat_frames_w začne narastať
rx_stat_drop_w môže narastať, ak FCS/MAC check zlyhá
```

Ak `rx_stat_frames_w` stále ostane nula, problém je ešte pred RX MAC FSM.

---

## Záver

Kompilačne je projekt už v dobrom stave:

```text
genvar chyba odstránená
Quartus build OK
Timing OK
CRC wrapper/taxi_lfsr prešli syntézou
```

Ale funkčne máš v aktuálnom `eth_rx_mac.sv` stále presne tú chybu, ktorú si už identifikoval v statuse:

```text
RXDV začína na SFD, ale ST_IDLE tento prvý bajt zahodí.
```

Toto je podľa mňa aktuálny hlavný dôvod, prečo clean MAC echo ešte nemusí fungovať v HW. Aplikoval by som najprv `eth_rx_mac_fix1.sv`; `eth_tx_mac_fix1.sv` je menší cleanup na odstránenie warningu a správnejší AXI-S štýl.

Tento výsledok je konzistentný s tým, že **TX odpoveď sa vôbec nevygeneruje**, nie iba že ju `test_loopback.py` zle vyhodnotí:

```text
FAIL ... no echo (timeout)
Result: 0/10 PASS
```

V clean režime test očakáva:

```text
RX z PC:
  DST = FPGA_MAC
  SRC = PC_MAC
  EtherType = 0x9000
  payload = test marker

TX z FPGA:
  DST = PC_MAC
  SRC = FPGA_MAC
  EtherType = 0x9000
  payload = rovnaký marker
```

Keď je všade `no echo`, najpravdepodobnejšie je:

```text
RX MAC nedá dobrú meta položku
alebo echo_app frame zahodí
alebo TX MAC nikdy nedostane meta/payload
```

---

## Najdôležitejšie: over, či máš naozaj aplikovaný RX SFD fix

V ZIP-e, ktorý som kontroloval, bol stále problém v `eth_rx_mac.sv`:

```systemverilog
ST_IDLE: begin
  win_cnt_q   <= 3'd0;
  rx_er_acc_q <= 1'b0;
  if (rxdv_q)
    state_q <= ST_PREAMBLE;
end
```

Toto je zle pre RTL8211EG, ak `RXDV` začne až na `D5`. Prvý bajt `D5` sa v `ST_IDLE` zahodí a ďalší bajt, teda `DST_MAC[0]`, sa interpretuje ako preambula. To spôsobí drop rámca hneď na začiatku. Tento problém je presne v oblasti modulu, ktorý sme už riešili pri `taxi_lfsr`/RX úpravách.

Správny `ST_IDLE` musí priamo spotrebovať prvý `RXDV` bajt:

```systemverilog
ST_IDLE: begin
  win_cnt_q   <= 3'd0;
  rx_er_acc_q <= 1'b0;

  if (rxdv_q) begin
    if (rxd_q == 8'hD5) begin
      // PHY asserts RXDV starting at SFD.
      // Consume SFD here and start Ethernet header parsing on next byte.
      state_q     <= ST_HEADER;
      hdr_cnt_q   <= 4'd0;
      crc_state_q <= 32'hFFFF_FFFF;
      pkt_bcast_q <= 1'b1;
      pkt_mcast_q <= 1'b0;
      mac_match_q <= 1'b0;
      rx_er_acc_q <= rxer_q;
      win_cnt_q   <= 3'd0;
      dst_mac_q   <= '0;
      src_mac_q   <= '0;
      eth_type_q  <= '0;
    end else if (rxd_q == 8'h55) begin
      // Some PHY/simulation paths may still expose preamble.
      state_q     <= ST_PREAMBLE;
      rx_er_acc_q <= rxer_q;
    end else begin
      // Bad first RXDV byte.
      rx_drop_q <= rx_drop_q + 16'd1;
      state_q   <= ST_IDLE;
    end
  end
end
```

Ak si tento patch ešte nezapracoval do reálne programovaného `.sof`, aktuálny `0/10 no echo` je očakávaný.

---

## Druhá vec: RX unit test v ZIP-e neprešiel

V poslednom ZIP-e boli v sim logoch chyby:

```text
tb_eth_rx_mac: 7 FAILURES
T1 FAIL: captured 0 bytes
T1 FAIL: tlast never seen
T3 FAIL: meta_fcs_ok=0 for valid frame
T6 FAIL: meta_fcs_ok=0 for broadcast frame
```

Čiže pred HW testom musí byť zelené minimálne:

```bash
cd examples/eth_test_04/sim
make unit
```

Ale pozor, v `tb_eth_rx_mac.sv` je aj chyba testbenchu:

```systemverilog
logic gmii_rxd_drv;
```

má byť:

```systemverilog
logic [7:0] gmii_rxd_drv;
```

Inak testbench posiela do 8-bitového `gmii_rxd_i` iba 1-bitový signál. Questa na to aj upozorňuje:

```text
Connection width does not match width of port 'gmii_rxd_i'
```

Takže poradie je:

```text
1. opraviť tb_eth_rx_mac.sv: gmii_rxd_drv [7:0]
2. opraviť eth_rx_mac.sv: ST_IDLE musí akceptovať D5
3. spustiť make unit
4. až potom make compile/program/loopback-test
```

---

## Prečo tento fail ešte nehovorí nič o CRC

Keď všetkých 10 testov skončí `no echo`, ešte nevieme, či je problém v CRC. Ak by bol problém len vo výstupnom FCS TX MAC-u, často by si videl aspoň zmenu NIC CRC/FCS error counterov alebo TX aktivitu na LED/pcap. Tu test nič nevidí.

To znamená, že treba najprv zistiť, kde sa frame stratí:

```text
RX frame prijatý?
RX payload vyšiel?
RX meta valid vznikol?
RX meta fcs_ok = 1?
meta prešla cez FIFO?
echo_app vytvorila tx_meta?
TX MAC začal vysielať?
```

---

## Dočasne zmeň debug výstupy

Teraz máš:

```systemverilog
assign dbg_mac_data_o = rx_stat_frames_w[7:0];
assign dbg_ctrl_o     = tx_stat_frames_w[7:0];
```

To je málo. Pri `0/10` potrebuješ vidieť vnútorné eventy. Dočasne daj:

```systemverilog
assign dbg_mac_data_o = {
  rx_tvalid_w,          // bit7: RX payload byte emitted
  rx_tlast_w,           // bit6: RX payload frame end
  rx_meta_valid_w,      // bit5: RX metadata created
  rx_meta_fcs_ok_w,     // bit4: RX frame accepted
  rx_stat_overflow_w,   // bit3: RX MAC overflow
  overflow_sticky_q,    // bit2: payload FIFO overflow
  rx_stat_drop_w[0],    // bit1: RX drop parity
  rx_stat_frames_w[0]   // bit0: RX frame parity
};

assign dbg_ctrl_o = {
  mfifo_rd_valid_w,       // bit7: meta FIFO has data in TX domain
  mfifo_rd_ready_w,       // bit6: echo_app consumes meta
  pfifo_rd_valid_w,       // bit5: payload FIFO has data
  pfifo_rd_ready_w,       // bit4: echo_app consumes payload
  txm_meta_valid_w,       // bit3: echo_app sends TX metadata
  txm_tvalid_w,           // bit2: echo_app sends TX payload
  eth_txen_o,             // bit1: GMII TX active
  tx_stat_underflow_w[0]  // bit0: TX underflow parity
};
```

Potom jeden `make loopback-test` okamžite povie:

```text
rx_meta_valid=0:
  RX MAC nedošiel ani na koniec rámca alebo dropol SFD/header.

rx_meta_valid=1, rx_meta_fcs_ok=0:
  RX prijal frame, ale FCS/MAC/length check zlyhal.

rx_meta_fcs_ok=1, mfifo_rd_valid=0:
  meta FIFO/write side problém.

mfifo_rd_valid=1, txm_meta_valid=0:
  echo_app problém.

txm_meta_valid=1, eth_txen=0:
  TX MAC problém.

eth_txen=1, ale PC nič nevidí:
  TX FCS/GMII/PHY/NIC drop.
```

---

## Ešte jeden praktický test

Spusti paralelne:

```bash
sudo tcpdump -i enp0s31f6 -e -n -XX 'ether proto 0x9000 or ether host 00:0a:35:01:fe:c0'
```

V druhom termináli:

```bash
make loopback-test
```

Ak tcpdump ukáže len odchádzajúce PC framy a nič z FPGA, problém je pred alebo v TX MAC.

Ak sa zvýši NIC CRC/FCS counter, ale tcpdump nič neukáže, FPGA možno vysiela zlé FCS:

```bash
ethtool -S enp0s31f6 | grep -iE 'crc|fcs|error|bad'
```

---

## Môj aktuálny verdikt

Najpravdepodobnejšie stále nebeží správne RX MAC začiatok frame:

```text
RXDV začína na SFD 0xD5,
ale RX FSM prvý RXDV bajt zahodí,
tým pádom neparsuje Ethernet header,
nevznikne dobrá meta,
echo_app nemá čo poslať,
TX ostane ticho.
```

Druhá vec je, že RX simulácia musí byť opravená a zelená. Kým `tb_eth_rx_mac` neprejde, HW `loopback-test` je len hádanie.
