Tento `eth_test_04(8)` je už iný projekt než predchádzajúci čistý L2 loopback. Vidím, že si postúpil ďalej a pridal si plnú smerovaciu cestu:

```text
eth_rx_mac
  -> eth_type_demux
      -> ARP path
      -> IPv4 path
          -> ICMP echo
          -> UDP echo
  -> ipv4_tx
  -> eth_tx_arb
  -> eth_tx_mac
```

ZIP:

```text
eth_test_04(8).zip
SHA-256: e78453f916ab48beaa87bd0aa7584951b36dde5c1daa3e59bdf716317838bc4f
```

## Krátky verdikt

Funkčne si spravil veľký krok dopredu: v projekte už existujú moduly pre ARP, IPv4 RX/TX, ICMP echo aj UDP echo a ich unit testy prechádzajú.

Ale aktuálny build **nie je timing-clean**:

```text
ETH_TX_CLK setup slack: -3.562 ns
TNS: -314.743 ns
```

To je zásadné. Predtým sme mali stabilný MAC/L2 projekt, ktorý bol HW overený. Teraz máš bohatší L2/L3/L4 stack, ale 125 MHz TX doména už časovo nestíha. Preto by som tento bitstream nepovažoval za spoľahlivý, aj keď niektoré testy môžu náhodne fungovať.

---

# Čo je dobré

## 1. RX sampling fix zostal zachovaný

V top-e stále používaš:

```systemverilog
altddio_in #(
  .invert_input_clocks ("ON"),
  .width               (8)
) u_rxd_ddr (...)
```

a `eth_rx_mac` aj `gmii_raw_tap` už idú z `rxd_s_w`, `rxdv_s_w`, `rxer_s_w`.

To je správne. Tento fix by som už považoval za štandard pre túto dosku.

## 2. Simulácie vrstiev prechádzajú

Zo sim logov:

```text
tb_eth_crc32_8      ALL PASS
tb_eth_rx_mac       ALL PASS
tb_eth_tx_mac       ALL PASS
tb_eth_echo_app     ALL PASS
tb_rx_tx_loopback   ALL PASS
tb_arp              ALL PASS
tb_icmp_echo        ALL PASS
tb_udp_echo         ALL PASS
```

Toto je výborné. Znamená to, že jednotlivé bloky majú rozumnú funkčnú logiku.

## 3. L2 loopback capture stále ukazuje 10/10 PASS

Capture v ZIP-e:

```text
captures/eth04_loopback-clean_20260606_131309/test_output.txt
Result: 10/10 PASS
```

To potvrdzuje, že predchádzajúci MAC/L2 základ bol zdravý.

---

# Najväčší problém: ETH_TX_CLK timing fail

V `soc_top.sta.summary`:

```text
Slow 85C Setup ETH_TX_CLK: -3.562 ns
Slow 0C  Setup ETH_TX_CLK: -2.861 ns
```

Toto nie je drobná rezerva. Pri 125 MHz máš periódu 8 ns a najhoršie cesty majú efektívne okolo 10+ ns.

Najhoršie cesty idú napríklad:

```text
icmp_echo RAM/bypass
  -> eth_tx_mac.gmii_txd_o / crc_state_q / fcs_shift_q

udp_echo RAM
  -> eth_tx_mac.crc_state_q / fcs_shift_q
```

Čiže problém je presne v tom, že výstup z vyšších vrstiev, prípadne RAM/bypass logiky, ide cez arbiter a TX MAC do CRC/FCS/GMII výstupov v jednom cykle.

Zjednodušene:

```text
udp_echo/icmp_echo RAM data
  -> eth_tx_arb mux
  -> eth_tx_mac payload/header mux
  -> eth_crc32_8 kombinačný CRC
  -> crc_state/fcs_shift/gmii_txd register
```

To je príliš dlhé na 125 MHz v Cyclone IV.

---

# Prečo prechádzajú simulácie, ale HW môže zlyhať

Simulácia overuje funkčný handshake pri ideálnych časoch. Quartus však hovorí:

```text
reálna ETH_TX_CLK logika nestíha časovanie o ~3.5 ns
```

To znamená, že v HW môžu byť chyby typu:

```text
občas zlé TX bajty,
zlý FCS,
nesprávne hlavičky,
náhodné UDP/ICMP chyby,
funguje malý frame, padá väčší frame,
funguje pri izbovej teplote, padá inde.
```

Preto ďalší krok nemá byť hneď debug protokolu, ale **rozbitie TX dátovej cesty na kratšie pipeline stupne**.

---

# Kde konkrétne je problém v architektúre

## 1. `eth_tx_arb -> eth_tx_mac` je príliš kombinačný

`eth_tx_arb` dáva:

```systemverilog
txm_tdata_w
txm_tvalid_w
txm_tlast_w
txm_tuser_w
```

priamo do `eth_tx_mac`.

`eth_tx_mac` potom v tom istom cykle používa dáta na:

```text
výber výstupného GMII bajtu
výpočet CRC32
posun FCS pipeline
rozhodovanie FSM
```

To je pri 125 MHz citlivé už pri samotnom L2 projekte. Po pridaní ARP/ICMP/UDP vrstiev a RAM výstupov sa cesta predĺžila.

## 2. `icmp_echo` a `udp_echo` majú RAM/bypass výstup priamo do TX

STA cesty ukazujú presne:

```text
icmp_data_mem_rtl_0_bypass[*] -> eth_tx_mac.gmii_txd_o[*]
udp_data_mem_rtl_0 ram_block -> eth_tx_mac.crc_state_q[*]
```

To znamená, že payload byte z RAM sa nestihne bezpečne dostať až do TX MAC CRC/output registra.

---

# Odporúčané RTL riešenie

## Krok 1 — vložiť registrovaný AXIS stage pred `eth_tx_mac`

Medzi `eth_tx_arb` a `eth_tx_mac` vlož 1-beat register slice:

```text
eth_tx_arb
  -> axis_register_slice
  -> eth_tx_mac
```

Register slice musí držať:

```text
tdata
tvalid
tready
tlast
tuser
```

a samostatne aj metadata:

```text
meta_valid
meta_ready
dst_mac
src_mac
eth_type
```

Najjednoduchšia bezpečná verzia: keď príde metadata, zaregistruj ju; potom payload stream ide cez registrovaný AXI stage.

Cieľ:

```text
RAM/arbiter output
  -> register
  -> eth_tx_mac CRC/output
```

Tým rozdelíš najdlhšiu cestu.

## Krok 2 — registrovať dáta v `eth_tx_mac` pred CRC

Ešte lepšie je upraviť `eth_tx_mac` tak, aby payload byte najprv zaregistroval:

```text
s_axis_tdata_i
  -> tx_byte_q
  -> CRC next / GMII output v ďalšom cykle
```

Momentálne to pravdepodobne robí príliš priamo:

```text
s_axis_tdata_i -> crc_next -> crc_state_q
s_axis_tdata_i -> gmii_txd_o
```

Odporúčaná vnútorná pipeline:

```text
Stage A:
  prijať payload/header/pad byte do tx_byte_q
  tx_byte_valid_q
  tx_byte_last_q
  tx_byte_crc_en_q

Stage B:
  gmii_txd_o <= tx_byte_q
  crc_state_q <= crc_next(tx_byte_q, crc_state_q)
```

Tým sa z CRC cesty odstráni arbiter/RAM logika.

## Krok 3 — oddeliť FCS výpočet od výstupného muxu

`crc_state_q` a `fcs_shift_q` sú v najhorších cestách. Preto po poslednom payload/pad byte sprav explicitný stav:

```text
ST_FCS_PREP:
  fcs_shift_q <= ~crc_state_q

ST_FCS0..ST_FCS3:
  vysielaj fcs_shift_q[7:0], ...
```

Nemiešaj výpočet FCS a výber ďalšieho bajtu v tom istom cykle, kde ešte prichádza payload z RAM.

---

# Odporúčaná architektúra pre TX časovanie

Teraz máš približne:

```text
ARP/ICMP/UDP source
  -> eth_tx_arb
  -> eth_tx_mac
  -> GMII
```

Navrhujem:

```text
ARP/ICMP/UDP source
  -> eth_tx_arb
  -> eth_tx_stage_fifo/register_slice
  -> eth_tx_mac_pipelined
  -> GMII
```

Ak chceš rýchly fix, použi malý FIFO/register slice:

```systemverilog
axis_fifo #(
  .DATA_WIDTH(10),
  .DEPTH(4)
) u_tx_axis_stage_fifo (...);
```

Ale pozor: metadata musia zostať spárované s payloadom. Preto nestačí len payload FIFO, treba buď:

```text
a) meta register + payload register slice,
```

alebo:

```text
b) spoločný packetizovaný TX staging modul, ktorý prijme meta a celý payload frame.
```

Pre začiatok by som spravil jednoduchý `eth_tx_stage.sv`:

```text
input:
  s_meta_valid/ready + s_meta_*
  s_axis_tdata/tvalid/tready/tlast/tuser

output:
  m_meta_valid/ready + m_meta_*
  m_axis_tdata/tvalid/tready/tlast/tuser

vlastnosť:
  zaregistruje metadata
  zaregistruje každý payload beat
  nemení poradie
```

---

# Druhý problém: `udp_echo.local_port_i = 16'd7`

V top-e máš:

```systemverilog
.local_port_i  (16'd7),     // echo port (RFC 862)
.promiscuous_i (1'b1),      // accept all UDP ports
```

Pre tvoje testy na port 8080 to teraz funguje iba preto, že:

```systemverilog
promiscuous_i = 1
```

Ak chceš testovať reálny UDP echo na 8080, odporúčam:

```systemverilog
.local_port_i  (16'd8080),
.promiscuous_i (1'b0)
```

Pre bring-up môžeš nechať promiscuous, ale potom si v statuse jasne napíš:

```text
UDP echo prijíma všetky porty, lokálny port filter je vypnutý.
```

---

# Tretí problém: analyzer stále nerozumie L2 0x9000 testu

V capture summary:

```text
Class counts:
  FPGA_OTHER: 10
  TO_FPGA_OTHER: 10

Diagnosis: No PC->FPGA UDP requests captured
```

Ale `test_output.txt` hovorí:

```text
Result: 10/10 PASS
```

To znamená, že analyzer stále nesprávne hodnotí `loopback-clean` capture. Treba ho upraviť, aby `eth.type == 0x9000` klasifikoval ako:

```text
PC_TO_FPGA_L2_TEST
FPGA_TO_PC_L2_ECHO
```

a pároval podľa `data_sha256`.

Toto nie je RTL problém, ale zhoršuje čitateľnosť artifacts.

---

# Štvrtý problém: `ETH_TEST_04_STATUS.md` je zastaraný

Status stále hovorí:

```text
Stav: UZAVRETY — altddio_in fix, loopback 10/10 PASS
```

Ale aktuálny top už tvrdí:

```text
Full L2/L3/L4 Ethernet stack: ARP echo, ICMP echo, UDP echo.
```

A STA hovorí:

```text
ETH_TX_CLK setup slack: -3.562 ns
```

Takže status už nie je pravdivý pre aktuálnu verziu. Odporúčam rozdeliť ho na:

```text
Fáza A: MAC/L2 echo — uzavretá, HW 10/10 PASS
Fáza B: ARP/ICMP/UDP stack — rozpracovaná, simulácie PASS, HW/timing nie je uzavretý
```

---

# Čo by som testoval teraz

Nie `trace-l2`. Ten už máme uzavretý.

Pre tento nový stack treba testovať samostatne:

```bash
make trace-udp-diag TRACE_TOOL=tcpdump
```

a pridať aj ARP/ICMP testy:

```bash
arping -I enp0s31f6 192.168.0.2
ping -I enp0s31f6 192.168.0.2
```

Ale pred HW testami by som riešil timing. Pri `ETH_TX_CLK -3.562 ns` môžu byť výsledky zavádzajúce.

---

# Priorita ďalšieho vývoja

## 1. Najprv timing

Cieľ:

```text
ETH_TX_CLK setup slack >= +0.5 ns
```

Minimálne:

```text
ETH_TX_CLK setup slack >= 0
```

Bez toho nemá zmysel dôverovať UDP/ICMP HW výsledkom.

## 2. Potom ARP

Najjednoduchší protokol:

```bash
arping -I enp0s31f6 192.168.0.2
```

Ak ARP prejde, L2 + eth_type_demux + arp_rx/tx + arbiter + tx_mac cesta funguje.

## 3. Potom ICMP

```bash
ping -I enp0s31f6 192.168.0.2
```

Overí IPv4 RX/TX + ICMP.

## 4. Potom UDP

```bash
make trace-udp-diag TRACE_TOOL=tcpdump
```

---

## Záver

Postúpili ste správnym smerom: `eth_test_04` už nie je len MAC loopback, ale začína byť plný ARP/ICMP/UDP stack. Funkčne je modulárne dobre rozložený a simulácie prechádzajú.

Ale aktuálny hlavný blocker je:

```text
ETH_TX_CLK setup timing fail -3.562 ns
```

Najbližšia úloha nie je hľadať ďalší protokolový bug, ale **zapipelínovať TX cestu medzi ARP/ICMP/UDP zdrojmi, arbiterom a `eth_tx_mac`**.

Až keď bude `ETH_TX_CLK` timing clean, má zmysel hodnotiť HW výsledky ARP/ping/UDP.
