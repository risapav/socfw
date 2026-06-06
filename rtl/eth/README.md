# socfw/rtl/eth — IEEE 802.3 Ethernet RTL Library

Reusable SystemVerilog modules pre GMII 1 Gbps Ethernet na Cyclone IV E
(QMTech EP4CE55). Overené v HW: ARP 4/4, ICMP 6/6, UDP echo 10/10 PASS.

Pôvod: `examples/eth_test_04`, commit `6ada345`.

---

## Adresárová štruktúra

```
rtl/eth/
  mac/
    taxi_lfsr.sv        – parametrizovateľný LFSR/CRC kombinačný blok (3rd party)
    eth_crc32_8.sv      – CRC32 IEEE 802.3 (8-bit/cycle wrapper nad taxi_lfsr)
    gmii_rx_mac.sv      – GMII RX → AXI-Stream (preamble/SFD strip, štatistiky)
    gmii_tx_mac.sv      – AXI-Stream → GMII TX (preamble/SFD/FCS/IFG generátor)
    eth_rx_mac.sv       – Ethernet RX: GMII → payload stream + metadata (FCS check, MAC filter)
    eth_tx_mac.sv       – Ethernet TX: metadata + payload stream → GMII (header/FCS generátor)
  l2/
    arp_rx.sv           – ARP request parser (IPv4/Ethernet, validácia, výstup requester MAC+IP)
    arp_tx.sv           – ARP reply builder (generuje 28B payload pre eth_tx_mac)
  l3/
    ipv4_rx.sv          – IPv4 header parser (20B IHL=5, MAC filter, forwarding)
    ipv4_tx.sv          – IPv4 header builder (checksum pipeline, prepend 20B header)
    icmp_echo.sv        – ICMP echo reply (type 8→0, checksum adjust, M9K buffer)
  l4/
    udp_echo.sv         – UDP echo RFC 862 (port filter, M9K buffer, checksum=0)
  util/
    eth_tx_arb.sv       – 3-to-1 fixed-priority TX arbiter (ARP>ICMP>UDP, skid buffer)
    eth_type_demux.sv   – EtherType 1→2 demux (ARP/IPv4, early header routing)
```

---

## Architektúra a dátový tok

### RX cesta

```
FPGA pin (125 MHz PHY)
  ↓  [altddio_in invert_input_clocks="ON"]   ← povinné pre Cyclone IV + RTL8211EG
gmii_rx_dv / gmii_rxd / gmii_rx_er
  ↓
eth_rx_mac                ← preamble/SFD strip, FCS check (CRC32), MAC unicast/bcast filter
  ├─ m_axis_t*            ← payload AXI-Stream (bez header, bez FCS), no backpressure
  ├─ m_hdr_valid_o        ← 1-cycle pulse: hlavička sparsovaná, ešte pred 1. payload bajtom
  └─ m_meta_valid         ← metadata (dst/src MAC, EtherType, fcs_ok) spolu s tlast
  ↓
[CDC: payload_fifo + meta_fifo]              ← RX_CLK → TX_CLK domain crossing
  ↓  (TX clock domain)
eth_type_demux            ← routuje podľa EtherType: port0=ARP(0x0806), port1=IPv4(0x0800)
  ├─ port0 → arp_rx
  └─ port1 → ipv4_rx → icmp_echo
                        → udp_echo
```

### TX cesta

```
arp_tx   ──┐
icmp_echo ─┤  eth_tx_arb   ← 3-to-1 fixed-priority, frame-level arbitrácia, skid buffer
udp_echo  ─┘       ↓
                eth_tx_mac  ← header (14B) + payload + zero-pad + FCS (CRC32) + IFG
                    ↓
              gmii_tx* (GMII TX, 125 MHz)
                    ↓
              [altddio_out invert_output="ON"]  ← povinné pre GTxCLK výstup
              FPGA pin
```

### CDC (Clock Domain Crossing)

`eth_rx_mac` pracuje v `eth_rx_clk_i` doméne (125 MHz, asynchrónny voči TX).
Zvyšok stacku (demux, L3/L4, arbiter, eth_tx_mac) beží v `eth_tx_clk_i` doméne.

CDC premostenie musí byť v top-level module pomocou async FIFO:

```systemverilog
// payload: DATA_WIDTH=10 (8b data + tlast + tuser), DEPTH=2048
cdc_async_fifo #(.DATA_WIDTH(10), .DEPTH(2048)) u_payload_fifo (...);

// metadata: DATA_WIDTH=113 (dst_mac+src_mac+eth_type+fcs_ok), DEPTH>=32
// DEPTH>=32 pre Cyclone IV E dual-clock BRAM inference (min 3072 bits)
cdc_async_fifo #(.DATA_WIDTH(113), .DEPTH(32)) u_meta_fifo (...);
```

---

## Moduly — stručný prehľad

### `gmii_rx_mac` — GMII RX → AXI-Stream

Vstup: RAW GMII (`gmii_rx_dv`, `gmii_rxd[7:0]`, `gmii_rx_er`).
Výstup: AXI-Stream bez preamble/SFD, s FCS v streame.

| Parameter     | Default | Popis                        |
|---------------|---------|------------------------------|
| `DATA_WIDTH`  | 8       | Šírka dát (GMII = 8)         |

Štatistické výstupy (1-cycle pulzy):
`stat_rx_pkt_good`, `stat_rx_pkt_bad`, `stat_rx_pkt_ucast/mcast/bcast/vlan`,
`stat_rx_err_bad_fcs` (stub 0 — CRC check je v `eth_rx_mac`).

**Timing:** RTL8211EG asertuje RXDV od SFD (0xD5), nie od preamble.

---

### `gmii_tx_mac` — AXI-Stream → GMII TX

Generuje preamble (7×0x55), SFD (0xD5), payload, FCS, IFG.
CRC32 integrovaný. Všetky výstupy registrované.

Vstup: AXI-Stream s metadátami (dst_mac, src_mac, eth_type) separátne od payloadu.

---

### `eth_rx_mac` — Ethernet RX MAC

Kľúčový RX modul. Nadstavba nad `gmii_rx_mac` s:
- stripping preamble/SFD + Ethernet hlavičky (14B) + FCS (4B)
- CRC32 verifikácia (5-byte posuvné okno)
- MAC filter: unicast (`LOCAL_MAC`), broadcast (`ACCEPT_BROADCAST`), multicast (`ACCEPT_MULTICAST`)

| Parameter         | Default            | Popis                         |
|-------------------|--------------------|-------------------------------|
| `LOCAL_MAC`       | 48'h000A3501FEC0   | FPGA MAC adresa               |
| `ACCEPT_BROADCAST`| 1                  | Akceptovať broadcast          |
| `ACCEPT_MULTICAST`| 0                  | Akceptovať multicast          |
| `MAX_FRAME_LEN`   | 1518               | Max. veľkosť rámca s FCS     |

Výstupy:
- `m_axis_t*` — payload stream (bez hlavičky, bez FCS), **no backpressure**
- `m_hdr_valid_o` — 1-cycle pulse keď je hlavička sparsovaná (pred 1. payload bajtom, 5 cyklov marže)
- `m_meta_valid` — metadata (dst/src MAC, EtherType, `fcs_ok`) spolu s `m_axis_tlast`

**Dôležité:** `m_axis_tready` nie je implementovaný (overflow je tichý). Downstream musí byť vždy ready alebo použiť FIFO.

---

### `eth_tx_mac` — Ethernet TX MAC

Generuje kompletný Ethernet rámec: header (14B) + payload + zero-pad + FCS + IFG.

| Parameter    | Default | Popis                                  |
|--------------|---------|----------------------------------------|
| `IFG_CYCLES` | 12      | Inter-frame gap (IEEE 802.3 min = 12)  |

Vstup:
- `s_meta_*` — metadata (dst_mac, src_mac, eth_type), 1 per frame
- `s_axis_*` — payload AXI-Stream

Underflow (tvalid=0 počas ST_PAYLOAD): asertuje TXER, abortuje rámec.

---

### `eth_type_demux` — EtherType 1→2 demux

Konzumuje `m_hdr_valid_o` z `eth_rx_mac` na rozhodnutie routingu **pred** príchodom prvého payload bajtu.

| Parameter    | Default | Popis                          |
|--------------|---------|--------------------------------|
| `ETH_TYPE_0` | 0x0806  | ARP → výstup port 0            |
| `ETH_TYPE_1` | 0x0800  | IPv4 → výstup port 1           |

Rámce s neznámym EtherType alebo `mac_ok=0` sú ticho zahodené.
**No backpressure** na vstupe — downstream musí byť vždy ready.

Timing: routing rozhodnutie je latchnuté 1 cyklus po `s_hdr_valid_i`.
Prvý payload bajt prichádza 6 cyklov po `s_hdr_valid_i` (5-cyklová marža z FCS okna).

---

### `arp_rx` — ARP request parser

Parsuje 28-bajtový ARP payload (po Ethernet header strip).
Validuje: `htype=0x0001, ptype=0x0800, hlen=6, plen=4, oper=0x0001, tpa==LOCAL_IP`.

| Parameter  | Default      | Popis                        |
|------------|--------------|------------------------------|
| `LOCAL_IP` | 32'hC0A80002 | FPGA IP (192.168.0.2)        |

Výstup: `m_valid_o` + `m_requester_mac_o[47:0]` + `m_requester_ip_o[31:0]`.
**CDC:** výstup je v RX clock doméne → treba async FIFO do TX domény pred `arp_tx`.

---

### `arp_tx` — ARP reply builder

Generuje 28-bajtový ARP reply payload pre `eth_tx_mac`.
Konzumuje `m_valid_o` z `arp_rx` (cez CDC FIFO, v TX clock doméne).

| Parameter   | Default            | Popis                 |
|-------------|--------------------|-----------------------|
| `LOCAL_MAC` | 48'h00_0A_35_01_FE_C0 | FPGA MAC          |
| `LOCAL_IP`  | 32'hC0A80002       | FPGA IP               |

FSM: `ST_IDLE → ST_TX_META → ST_TX_PAYLOAD` (28B) `→ ST_IDLE`.

---

### `ipv4_rx` — IPv4 header parser

Stripuje 20-bajtový IPv4 header (IHL musí byť 5; options → drop).

| Parameter     | Default      | Popis                              |
|---------------|--------------|------------------------------------|
| `LOCAL_IP`    | 32'hC0A80002 | FPGA IP pre dst_ip filter          |
| `PROMISCUOUS` | 0            | 1 = akceptovať všetky dst_ip       |

Výstup:
- `m_hdr_valid_o` — 1-cycle registered pulse, fires v 1. cykle ST_PAYLOAD
- `m_axis_tuser` — 1 ak rámec má byť zahodený (zlý IHL, wrong IP, fragment, upstream error)
- `m_meta_valid_o` — metadata spolu s `m_axis_tlast`

**Kritické:** `m_hdr_valid_o` môže prísť v rovnakom cykle ako prvý `m_axis_tvalid` beat.
Downstream protokoly musia použiť kombinačné routovanie na `s_ip_hdr_valid_i`.

---

### `ipv4_tx` — IPv4 header builder

Prepend-uje 20-bajtový IPv4 header. Checksum výpočet v 4 pipelined stavoch
(`CSUM0..3`) — každý adder má presne 2 operandy (125 MHz timing constraint).

| Parameter   | Default            | Popis                     |
|-------------|---------------------|---------------------------|
| `LOCAL_IP`  | 32'hC0A80002        | FPGA zdrojová IP          |
| `LOCAL_MAC` | 48'h00_0A_35_01_FE_C0 | FPGA MAC (pre eth_tx_mac) |

Vstup: `s_meta_proto_i`, `s_meta_dst_ip_i`, `s_meta_dst_mac_i`, `s_meta_payload_len_i`.
Latencia: 7 cyklov od meta accept po prvý výstupný bajt.
Výstup do `eth_tx_arb` (nie priamo do `eth_tx_mac`).

---

### `icmp_echo` — ICMP echo reply

Bufferuje ICMP echo request (type=8), generuje reply (type=0).
Checksum adjustmet: `reply_csum = fold(request_csum + 0x0800)`.
Payload buffering v `icmp_data_mem[]` (M9K, `MAX_DATA_BYTES`).

| Parameter        | Default      | Popis                          |
|------------------|--------------|--------------------------------|
| `LOCAL_IP`       | 32'hC0A80002 | Prenesené do ipv4_tx           |
| `MAX_DATA_BYTES` | 1500         | Max ICMP data bytes (id+seq+data) |

Jeden rámec naraz: nové rámce sú ignorované kým TX neprebehne.
**TX RAM timing:** `tx_rd_addr_q` beží 1 cyklus pred `tx_out_cnt_q` (M9K read-ahead pattern).

---

### `udp_echo` — UDP echo RFC 862

Parsuje 8-bajtový UDP header, bufferuje payload, generuje echo reply.
Checksum = 0x0000 (RFC 768 voliteľný).

| Parameter        | Default | Popis                               |
|------------------|---------|-------------------------------------|
| `MAX_DATA_BYTES` | 1472    | Max UDP payload bytes               |

Runtime konfigurácia:
- `local_port_i[15:0]` — filtrovaný UDP port
- `promiscuous_i` — 1 = akceptovať všetky porty (ignoruje `local_port_i`)

**TX RAM timing:** rovnaký M9K read-ahead pattern ako `icmp_echo`.

---

### `eth_tx_arb` — 3-to-1 TX arbiter

Fixed-priority arbitrácia na úrovni rámcov (bez preemcie).
Priorita: port0 (ARP) > port1 (ICMP) > port2 (UDP).

Payload výstup je **registrovaný** (skid buffer / 1-stage pipeline).
Tým sa prereruší kombinačná cesta z M9K RAM cez 3-way mux do `eth_tx_mac` —
kľúčové pre timing closure na 125 MHz v Cyclone IV.

`pipe_ready_w = m_axis_tready_i || !m_tvalid_q` — upstream môže predplniť pipeline
1 cyklus pred downstream konzumáciou.

---

## Timing closure — pravidlá pre 125 MHz (Cyclone IV E)

### M9K RAM timing pattern

Každý blok s M9K RAM feedujúci streaming TX dáta musí používať:

```systemverilog
// SPRÁVNE: Quartus inferuje M9K s outdata_reg → eliminuje portb_address_reg0 z kritickej cesty
always_ff @(posedge clk_i) begin
  tx_data_byte_q <= mem[tx_rd_addr_q[ADDR_W-1:0]];
end
```

```systemverilog
// NESPRÁVNE: portb_address_reg0 -> M9K read ~7 ns -> mux -> dst FF = 10+ ns > 8 ns budget
assign tx_data_byte_w = mem[addr];  // kombinačný read → timing fail
```

FSM musí používať **read-ahead pointer**:
- `tx_rd_addr_q` — read pointer, 1 cyklus pred výstupom
- `tx_out_cnt_q` — output counter pre tlast detekciu

Na TX_HDR→TX_DATA prechode: `tx_rd_addr_q <= 1` zatiaľčo `always_ff` číta `mem[0]` na
rovnakom hrane → `mem[0]` je pripravený v TX_DATA cykle 0.

### altddio_in (RTL8211EG + Cyclone IV E)

PCB trace delay + crosstalk spôsobuje glitche na RXD[3:0] pri nabehovej hrane RX_CLK.
**Povinné** vzorkovanie na zostupnej hrane:

```systemverilog
`ifdef SYNTHESIS
  altddio_in #(
    .intended_device_family ("Cyclone IV E"),
    .invert_input_clocks    ("ON"),
    .width                  (8)
  ) u_rxd_ddr (
    .datain    (eth_rxd_i),
    .inclock   (eth_rx_clk_i),
    .dataout_h (rxd_s_w)   // falling-edge capture = 4 ns neskôr = stred dátového okna
  );
`else
  assign rxd_s_w = eth_rxd_i;  // sim fallback
`endif
```

Analogicky pre `rxdv` (width=1) a `rxer` (width=1).

### altddio_out (GTxCLK)

GTxCLK výstup musí byť invertovaný:

```systemverilog
altddio_out #(
  .intended_device_family ("Cyclone IV E"),
  .invert_output          ("ON"),
  .width                  (1)
) u_gtx_clk_ddr (
  .datain_h (1'b1),
  .datain_l (1'b0),
  .outclock (eth_tx_clk_i),
  .dataout  (eth_gtx_clk_o)
);
```

### meta_fifo DEPTH

Cyclone IV E dual-clock BRAM inference vyžaduje minimálne 3072 bits.
Pre `DATA_WIDTH=113` (metadata): `DEPTH >= 32` (113 × 32 = 3616 bits).
Menšia hĺbka → Quartus inferuje LUT RAM bez dual-clock podpory → CDC fail.

---

## Príklad zapojenia (minimálny ARP + ICMP + UDP stack)

```systemverilog
// Parametre
localparam logic [47:0] LOCAL_MAC = 48'h00_0A_35_01_FE_C0;
localparam logic [31:0] LOCAL_IP  = 32'hC0A8_0002;

// --- RX clock domain ---
wire [7:0] rxd_s_w;
wire       rxdv_s_w, rxer_s_w;

// altddio_in (povinné pre RTL8211EG)
// ... u_rxd_ddr, u_rxdv_ddr, u_rxer_ddr

eth_rx_mac #(
  .LOCAL_MAC        (LOCAL_MAC),
  .ACCEPT_BROADCAST (1'b1)
) u_rx_mac (
  .clk_i          (eth_rx_clk_i),
  .rst_ni          (rst_ni),
  .gmii_rxd_i      (rxd_s_w),
  .gmii_rx_dv_i    (rxdv_s_w),
  .gmii_rx_er_i    (rxer_s_w),
  .m_axis_tdata    (rx_data_w),
  .m_axis_tvalid   (rx_valid_w),
  .m_axis_tlast    (rx_last_w),
  .m_axis_tuser    (rx_user_w),
  .m_hdr_valid_o   (rx_hdr_valid_w),
  .m_hdr_src_mac_o (rx_hdr_src_mac_w),
  .m_hdr_eth_type_o(rx_hdr_eth_type_w),
  .m_hdr_mac_ok_o  (rx_hdr_mac_ok_w),
  // ... meta ports
);

// CDC: payload_fifo (DATA_WIDTH=10, DEPTH=2048), meta_fifo (DATA_WIDTH=113, DEPTH=32)
// Používaj cdc_async_fifo z rtl/cdc/

// --- TX clock domain ---
eth_type_demux #(
  .ETH_TYPE_0 (16'h0806),
  .ETH_TYPE_1 (16'h0800)
) u_demux (
  .clk_i           (eth_tx_clk_i),
  .s_hdr_valid_i   (cdc_hdr_valid_w),
  .s_hdr_eth_type_i(cdc_hdr_eth_type_w),
  .s_hdr_mac_ok_i  (cdc_hdr_mac_ok_w),
  .s_axis_tdata    (cdc_data_w),
  .s_axis_tvalid   (cdc_valid_w),
  .s_axis_tlast    (cdc_last_w),
  .s_axis_tuser    (cdc_user_w),
  // port0 → arp_rx, port1 → ipv4_rx
  // ...
);

// arp_rx → (CDC FIFO) → arp_tx
// ipv4_rx → icmp_echo
//          → udp_echo

eth_tx_arb u_arb (
  .clk_i  (eth_tx_clk_i),
  // port0 ← arp_tx
  // port1 ← icmp_echo
  // port2 ← udp_echo
  // → eth_tx_mac
);

eth_tx_mac #(.IFG_CYCLES(12)) u_tx_mac (
  .clk_i  (eth_tx_clk_i),
  // ← eth_tx_arb
  .gmii_txd_o   (gmii_txd_w),
  .gmii_tx_en_o (gmii_tx_en_w),
  .gmii_tx_er_o (gmii_tx_er_w)
);

// altddio_out pre GTxCLK (povinné)
// gmii_txd_w → FPGA pin
```

---

## Čo NIE je v knižnici (project-specific)

| Súbor                       | Dôvod vynechania                              |
|-----------------------------|-----------------------------------------------|
| `ethernet_test_04_top.sv`   | Konkrétny top-level s pinmi QMTech EP4CE55    |
| `eth_echo_app.sv`           | L2 raw echo app (Faza A, nahradená L3/L4 stackom) |
| `gmii_raw_tap.sv`           | Debug tap (UART output), nie produkčný modul  |
| `rx_uart_debug.sv`          | Diagnostický modul                            |
| `uart_tx.sv`                | Duplikát — použiť `rtl/uart/`                 |
| `util/axis_fifo.sv`         | Single-clock only — použiť `rtl/axis/axis_fifo_sync.sv` alebo `rtl/cdc/cdc_async_fifo.sv` |

---

## Závislosti

```
taxi_lfsr           (leaf, CERN-OHL-S-2.0, Alex Forencich)
eth_crc32_8         → taxi_lfsr
gmii_rx_mac         (standalone)
gmii_tx_mac         (standalone, vlastný inline FCS)
eth_rx_mac          → eth_crc32_8
eth_tx_mac          → eth_crc32_8
arp_rx              (standalone)
arp_tx              (standalone)
ipv4_rx             (standalone)
ipv4_tx             (standalone)
icmp_echo           (standalone, M9K)
udp_echo            (standalone, M9K)
eth_tx_arb          (standalone)
eth_type_demux      (standalone)
```

Externé závislosti: `rtl/cdc/cdc_async_fifo.sv` (pre CDC vo vašom top-level).
