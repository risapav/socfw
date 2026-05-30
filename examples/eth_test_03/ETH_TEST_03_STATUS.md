# ETH_TEST_03 — Status

**Dátum:** 2026-05-30
**Stav:** Prebieha — 13/13 testbenches ALL PASS (`make regression`); vrátane tb_echo_path_dual_clock (CDC, rx_clk 8.000 ns / tx_clk 8.013 ns); zostáva HW top

---

## Cieľ projektu

Kompletný Ethernet UDP echo stack na QMTech EP4CE55 + RTL8211EG PHY (GMII 1Gbps).

```
RX: gmii_rx_mac -> eth_header_parser -> ipv4_header_parser -> udp_header_parser
                -> udp_rx_meta_assembler -> udp_echo_app
TX: udp_echo_app -> udp_ipv4_tx_builder -> gmii_tx_mac
```

---

## Stav RTL modulov

| Modul | Súbor | Stav |
|---|---|---|
| `crc32_eth` | `mac/crc32_eth.sv` | PASS — 3/3 |
| `gmii_tx_mac` | `mac/gmii_tx_mac.sv` | PASS — 8/8 (frame/padding/FCS/IFG) |
| `gmii_rx_mac` | `mac/gmii_rx_mac.sv` | PASS — 5/5; výstup s FCS (strip v budúcnosti) |
| `eth_header_builder` | `l2/eth_header_builder.sv` | PASS — 3/3 |
| `eth_header_parser` | `l2/eth_header_parser.sv` | PASS — 12/12 |
| `ipv4_checksum` | `l3/ipv4_checksum.sv` | PASS — 4/4 |
| `ipv4_header_parser` | `l3/ipv4_header_parser.sv` | PASS — 15/15 |
| `udp_header_parser` | `l4/udp_header_parser.sv` | PASS — 21/21; porty `hdr_pre_valid_o` + `_pre` |
| `udp_rx_meta_assembler` | `l4/udp_rx_meta_assembler.sv` | PASS (cez echo_path) |
| `udp_echo_app` | `l4/udp_echo_app.sv` | PASS (cez echo_path) |
| `udp_ipv4_tx_builder` | `l4/udp_ipv4_tx_builder.sv` | PASS — 3/3 |
| `ethernet_test_03_top` | `ethernet_test_03_top.sv` | Stub — dlhodobý cieľ |

Všetky RTL súbory sú v `examples/eth_test_03/rtl/eth/` (zdielaný adresár s ostatnými projektmi).

---

## Výsledky testov (12/12 testbenches ALL PASS)

### Makefile targets

```bash
make unit         # Questa: 10 unit/layer testov
make integration  # Verilator: rx_path + echo_path + echo_path_dc (dual-clock CDC)
make regression   # clean + unit + integration
```

Filelist pre linter: `sim/eth_test_03.f` (eth_pkg.sv ako prvý).

---

### tb_crc32_eth — PASS (3/3)
- T1: CRC32("123456789") = 0xCBF43926 ✓
- T2: `clear_i` resetuje na 0xFFFFFFFF ✓
- T3: `crc_next_o` preview = nasledujúci `crc_state_o` ✓

### tb_gmii_tx_mac — PASS (8/8)
- T1a: 72 bytov TX_EN=1 ✓ T1b: 45 padding ✓ T1c: FCS=0x244a21b4 ✓ T1d: IFG=12 cyklov ✓
- T2a: 72 bytov TX_EN=1 ✓ T2b: 46 payload, bez paddingu ✓ T2c: FCS=0xf1b32d3c ✓
- T3: gmii_tx_er=0 ✓

### tb_gmii_rx_mac — PASS (5/5)
- T1: prvý byte = 0xAA ✓ T2: tlast na poslednom byte ✓ T3: 0xD5 neprešlo ✓
- T4: 19 bytov zachytených ✓ DATA: všetkých 19 bytov sedí ✓

### tb_mac_stream_tx_rx_stream — PASS (10/10)
AXI-Stream → gmii_tx_mac → GMII loopback → gmii_rx_mac → AXI-Stream scoreboard.
- T1 (5-byte "HELLO"): 64 B, padding=0x00 (41 B) ✓, FCS=0xa398c1b3 ✓
- T2 (46-byte payload): 64 B, payload ✓, FCS=0xc581b6fb ✓

### tb_eth_header_builder — PASS (3/3)

### tb_eth_header_parser — PASS (12/12)
T1 (unicast match) ✓, T2 (broadcast) ✓, T3 (mismatch/drop) ✓, T4 (short frame reset) ✓, T5 (back-to-back) ✓

### tb_ipv4_checksum — PASS (4/4)
Vrátane fold2 carry path test ✓

### tb_ipv4_header_parser — PASS (15/15)
T1 (UDP/local_ip) ✓, T2 (wrong dst_ip/drop) ✓, T3 (TCP/drop) ✓, T4 (ver/IHL/drop) ✓, T5 (short frame) ✓, T6 (back-to-back) ✓

### tb_udp_header_parser — PASS (21/21)
- T1 (valid dst_port=8080, "HELLO" + trailing FCS): 5 bytes forwarded, padding zahodeé ✓
- T2 (wrong dst_port): ST_DROP ✓ T3 (udp_len < 8): ST_DROP ✓
- T4 (short header): FSM reset ✓ T5 (back-to-back) ✓
- T6 (zero payload udp_len=8): 0 bytes ✓, FSM recovery ✓
- T7 (nonzero checksum, DROP_NONZERO_CHECKSUM=0): accepted ✓, `udp_checksum_unchecked_o=1` ✓

### tb_udp_ipv4_tx_builder — PASS (3/3)
- T1 ("HELLO" 5 B): total_len=33 ✓, IPv4 csum=0xB778 ✓, UDP csum=0x0000 ✓, payload ✓
- T2 (3 B, iné IP): total_len=31 ✓, csum=0x26CC ✓
- T3 (back-to-back 1 B): FSM recovery ✓

### tb_rx_path (Verilator C++) — PASS (5/5)
GMII → gmii_rx_mac → eth_header_parser → ipv4_header_parser → udp_header_parser
- T1 (valid UDP "HELLO"): 5 bytes ✓ T2 (wrong dst_mac / L2 drop) ✓
- T3 (wrong dst_ip / L3 drop) ✓ T4 (wrong dst_port / L4 drop) ✓
- T5 (back-to-back valid frames): 3+4 bytes ✓

### tb_echo_path_dual_clock (Verilator C++) — PASS (5/5)
Dual-clock CDC: rx_clk=8.000 ns, tx_clk=8.013 ns; async FIFO (gray-code); TX controller waits for tx_busy_o=0.
- T1-T5: rovnaké ako single-clock ✓ — CDC hazardy neodhalené

### tb_echo_path (Verilator C++) — PASS (5/5)
GMII RX → plný echo stack → GMII TX; byte-by-byte verifikácia odpovede.
- T1 (valid UDP "HELLO"): echo response ✓ — dst/src MAC ✓, IP ✓, port ✓, payload ✓
- T2 (wrong dst_mac): no TX response ✓
- T3 (wrong dst_ip): no TX response ✓
- T4 (back-to-back valid frames): dve echo odpovede (3+4 bytes) ✓
- T5 (zero-payload udp_len=8): header-only echo response, 64-byte frame ✓

---

## Kľúčové RTL rozhodnutia

### hdr_pre_valid_o a _pre porty (timing fix)

2-byte payload offset bol root cause: assembler mal 1-cycle edge-detection delay + echo_app
mal 1-cycle ST_IDLE→ST_RX delay = spolu 2 bajty stratené.

**Fix:**
- `udp_header_parser` vystavuje `hdr_pre_valid_o` (fires pri `byte_cnt==7`, pred prechodom do ST_PAYLOAD)
- Kľúč: `header_reg_q` po 7 bajtoch má byte0 na `[55:48]` (nie `[63:56]`), takže `src_port_o`/`udp_len_o` sú v tomto cykle nesprávne. Správne hodnoty sú v `header_next_w` — preto existujú `_pre` porty:

```systemverilog
assign src_port_pre_o    = header_next_w[63:48];  // platné pri hdr_pre_valid_o=1
assign dst_port_pre_o    = header_next_w[47:32];
assign payload_len_pre_o = header_next_w[31:16] - 16'd8;
```

- `udp_rx_meta_assembler` triggeruje priamo na `udp_hdr_pre_valid_i` (bez edge detection)
- `udp_echo_app` má `s_axis_tready=1` aj v ST_IDLE keď `rx_meta_valid_i=1`; prvý payload bajt zachytený počas ST_IDLE→ST_RX handshake

### FCS politika
`gmii_rx_mac` posiela FCS ďalej. `udp_header_parser` je robustný — ST_FLUSH zahodí
trailing bytes (padding + FCS) podľa `udp_len`. STRIP_FCS = dlhodobý cieľ.

### UDP checksum (Fáza 1)
- TX: `udp_checksum = 0x0000` (disabled, povolené pre IPv4, RFC 768)
- RX: `DROP_NONZERO_CHECKSUM=0` — nonzero checksum akceptovaný, flag `udp_checksum_unchecked_o=1`

### rx_meta handshake
`udp_rx_meta_assembler` zachytáva metadata z troch parserov súčasne (pri `hdr_pre_valid_o`)
a drží ich vo `valid_q` do handshake s echo_app. `udp_echo_app.rx_meta_ready_o = (state_q==ST_IDLE)`.

### TX architektúra
Jeden kombinovaný `udp_ipv4_tx_builder`: vstup `tx_meta` + UDP payload → IPv4+UDP header (28 B) + payload.
`gmii_tx_mac.tx_start_i = tx_meta_valid && tx_meta_ready` (1-cyklový pulse pri handshake).

---

## Kľúčové TB lekcie

### Verilator C++ — persistent TX sampler
```cpp
// TX response môže začať POČAS send_frame(), nie po ňom!
// sample_tx() treba volať pri KAŽDOM posedge — aj v gmii_byte() lambde.
static void sample_tx() { /* detekcia SFD, akumulácia bytov */ }
static void tick() {
    dut->clk_i = 1; dut->eval();
    sample_tx();  // hneď po posedge
    dut->clk_i = 0; dut->eval();
}
```

### MAC output je REGISTERED
```systemverilog
assign m_axis_tdata = rxd_q;  // rxd_q <= gmii_rxd_i pri každom posedge
```
Všetky parsery: `m_axis_tdata = s_axis_tdata` (kombinačný priechodom) — celý reťazec má 1 register.

### Pre-NBA capture pattern (Questa TB)
```systemverilog
always @(posedge clk) begin
  signal_cap = signal; // blocking = — nie <=
end
```
Nutné pre `m_tvalid`, `hdr_valid`, `drop`, `csum_*` (NBA môže vymazať register v tej istej hranici).

### GMII preamble = 0x55, SFD = 0xD5
`gmii_rx_mac` detekuje `8'h55` (nie `8'hAA`). V C++ TB: `gmii_byte(0x55, true)` × 7, potom `gmii_byte(0xD5, true)`.

---

## Known Issues

### gmii_rx_mac ignoruje m_axis_tready
Zámerné — predpokladá line-rate downstream. Parsery kompenzujú ST_FLUSH/ST_DROP.

---

## Zostatok

- [x] `crc32_eth`, `gmii_tx_mac`, `gmii_rx_mac` + TBs — DONE
- [x] `eth_header_builder`, `eth_header_parser` + TBs — DONE
- [x] `ipv4_checksum`, `ipv4_header_parser` + TBs — DONE
- [x] `udp_header_parser` + TB (21/21) — DONE
- [x] `udp_rx_meta_assembler` — DONE
- [x] `udp_echo_app` (valid/ready, rx_meta_q latch, first-byte capture) — DONE
- [x] `udp_ipv4_tx_builder` + TB (3/3) — DONE
- [x] `tb_rx_path` (Verilator, 5/5) — DONE
- [x] `tb_echo_path` (Verilator, 5/5, vrátane zero-payload T5) — DONE
- [x] Zero-payload echo fix — DONE (hdr_pre_valid_o >= 16'd8; echo_app skip ST_RX; tx_builder tlast pri hdr_cnt==27)
- [x] `async_fifo.sv` (gray-code, dual-clock) — DONE
- [x] `echo_path_dual_clock_top.sv` + `tb_echo_path_dual_clock` (5/5 PASS) — DONE
- [ ] `ethernet_test_03_top.sv` — HW top integration (CDC async FIFO + gmii_tx_mac v TX doméne)
- [ ] `eth_debug_leds.sv` — LED diagnostika
- [ ] `gmii_rx_mac` STRIP_FCS — dlhodobý cieľ
