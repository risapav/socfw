Prešiel som nahraté súbory. Najdôležitejší záver: **aktuálny stav mieša dve rôzne verzie XFCP protokolu a dva rôzne bridge moduly**, preto je veľmi pravdepodobné, že `tb_xfcp_uart_mmio_top` visí pri čakaní na odpoveď z UART TX.

Stavový dokument hovorí, že priorita je integrovať `xfcp_uart_mmio_top.sv` s `xfcp_axil_bridge`, `axil_sys_ctrl`, `axil_uart_adapter`, `axil_regs` a `axil_seven_seg_adapter` . Nahratý `xfcp_uart_mmio_top.sv` však stále používa starší/alternatívny `axil_xfcp_mod`.

## 1. Hlavný problém: starý vs nový XFCP protokol

V `xfcp_uart_mmio_top.sv` a testbenchi je použitý starý formát:

```systemverilog
START = 0xFF
READ  = 0x10
WRITE = 0x12
READ response = 0x11
WRITE response = 0x13

packet:
[0xFF][opcode][addr 4B][len 2B][data]
```

Ale nové nahraté XFCP moduly používajú podľa `xfcp_pkg.sv`, `xfcp_rx_parser.sv` a `xfcp_tx_packetizer.sv` iný formát:

```systemverilog
SOP_REQ       = 0xFE
SOP_RESP      = 0xFE
SOP_RPATH     = 0xFF

READ          = 0x10
WRITE         = 0x11
RESP_READ     = 0x12
RESP_WRITE    = 0x13

packet:
[0xFE][opcode][count 2B][addr 4B][data]
```

Čiže rozdiely sú zásadné:

| Pole                 | Starý `axil_xfcp_mod` / TB |       Nový `xfcp_rx_parser` |
| -------------------- | -------------------------: | --------------------------: |
| request SOP          |                     `0xFF` |                      `0xFE` |
| WRITE opcode         |                     `0x12` |                      `0x11` |
| READ response opcode |                     `0x11` |                      `0x12` |
| poradie headera      |         `addr` potom `len` |        `count` potom `addr` |
| response header      |                     krátky | 20-bajtový header + payload |

Toto treba zjednotiť skôr, než pôjdeš ďalej.

## 2. Prečo log vyzerá ako deadlock

`tb_xfcp_uart_mmio_top.log` skončí na:

```text
# run -all
```

a ďalej už nie je ani:

```text
PASS ...
FAIL ...
ALL PASSED
```

To znamená, že testbench pravdepodobne visí v:

```systemverilog
xfcp_drain_write_resp();
```

konkrétne v `uart_recv()`, kde čaká na bajty z `uart_tx_o`.

Teda prvý WRITE buď:

1. nebol dekódovaný,
2. neprešiel cez AXI-Lite,
3. bridge neposlal odpoveď,
4. alebo UART monitor nezachytil odpoveď.

Najpravdepodobnejšie príčiny sú protokolový mismatch alebo TLAST problém.

## 3. Druhý veľký problém: `TLAST` z UART RX

V top komentári máš:

```systemverilog
UART stream: each byte has TLAST=1 (ignored by axil_xfcp_mod).
```

To je bezpečné len pre starý `axil_xfcp_mod`, ak TLAST ignoruje.

Nový `xfcp_rx_parser.sv` však `TLAST` používa ako koniec paketu a má ochrany ako:

```systemverilog
if (state_q == S_HDR && axis_fire && s_axis_tlast && !last_hdr_byte)
  go_drop = 1'b1;
```

Ak `axis_uart_rx` dáva `TLAST=1` na každý bajt, nový parser zahodí paket už počas headera. Pre UART režim teda nový parser potrebuje buď:

```systemverilog
s_axis_tlast = 1'b0;
```

alebo parameter typu:

```systemverilog
IGNORE_TLAST = 1
```

Inak sa nový bridge cez UART nerozbehne.

## 4. Čo by som opravil ako prvé

Odporúčam ísť touto cestou: **prestať používať `axil_xfcp_mod` a prepnúť top na nový `xfcp_axil_bridge`**, pretože podľa statusu je to cieľová architektúra.

V `xfcp_uart_mmio_top.sv` nahraď:

```systemverilog
axil_xfcp_mod #(
  .BIG_ENDIAN_DATA(1'b0)
) u_bridge (
  .m_axil  (axil_m.master),
  .xfcp_in (xfcp_rx_s.slave),
  .xfcp_out(xfcp_tx_s.master)
);
```

za:

```systemverilog
xfcp_axil_bridge #(
  .LITTLE_ENDIAN (1'b1),
  .AXI_ADDR_WIDTH(32),
  .AXI_DATA_WIDTH(32),
  .ID_STR        ("XFCP-UART-MMIO  ")
) u_bridge (
  .clk     (clk_i),
  .rst_n   (rst_ni),
  .xfcp_in (xfcp_rx_s.slave),
  .xfcp_out(xfcp_tx_s.master),
  .m_axil  (axil_m.master)
);
```

Ale zároveň nesmie ísť do parsera `TLAST=1` pri každom UART bajte. Najčistejšie je vložiť medzi UART RX a XFCP bridge malý „sanitizer“ stream:

```systemverilog
axi4s_if #(.DATA_WIDTH(8)) uart_rx_s (.TCLK(clk_i), .TRESETn(rst_ni));

axis_uart_rx u_uart_rx (
  .m_axis     (uart_rx_s.master),
  .rxd_i      (uart_rx_i),
  .prescale_i (baud_div_w[15:0]),
  .cfg_i      (uart_cfg_w),
  .status_o   (rx_status_w),
  .err_clear_i(err_clr_w)
);

assign xfcp_rx_s.TDATA  = uart_rx_s.TDATA;
assign xfcp_rx_s.TVALID = uart_rx_s.TVALID;
assign uart_rx_s.TREADY = xfcp_rx_s.TREADY;

// UART nemá prirodzený packet TLAST, parser si dĺžku vie odvodiť z COUNT.
assign xfcp_rx_s.TLAST  = 1'b0;
```

## 5. Testbench treba upraviť na nový protokol

Ak použiješ nový `xfcp_axil_bridge`, helpery v TB majú byť takto:

### WRITE request

```systemverilog
// [0xFE][0x11][count=4 BE][addr BE][data]
task automatic xfcp_write(
  input logic [31:0] addr,
  input logic [31:0] data
);
  uart_send(8'hFE);
  uart_send(8'h11);                  // WRITE
  uart_send(8'h00); uart_send(8'h04); // count = 4
  uart_send(addr[31:24]); uart_send(addr[23:16]);
  uart_send(addr[15:8]);  uart_send(addr[7:0]);

  // POZOR: nový parser skladá payload MSB-first do 32-bit slova
  uart_send(data[31:24]);
  uart_send(data[23:16]);
  uart_send(data[15:8]);
  uart_send(data[7:0]);
endtask
```

### READ request

```systemverilog
// [0xFE][0x10][count=4 BE][addr BE]
task automatic xfcp_read(input logic [31:0] addr);
  uart_send(8'hFE);
  uart_send(8'h10);                  // READ
  uart_send(8'h00); uart_send(8'h04); // count = 4
  uart_send(addr[31:24]); uart_send(addr[23:16]);
  uart_send(addr[15:8]);  uart_send(addr[7:0]);
endtask
```

### WRITE response

Nový packetizer neposiela len `[SOP][opcode]`, ale 20-bajtový header:

```text
[0xFE][0x13][DEV_TYPE 2B][DEV_STR 16B][0x00 end]
```

Takže `xfcp_drain_write_resp()` nemôže čítať iba 2 bajty. Minimálne pre začiatok:

```systemverilog
task automatic xfcp_drain_write_resp();
  logic [7:0] b;
  // 20-byte response header + final 0x00/TLAST byte
  for (int i = 0; i < 21; i++) begin
    uart_recv(b);
  end
endtask
```

### READ response

Pri READ response príde:

```text
[0xFE][0x12][DEV_TYPE 2B][DEV_STR 16B][payload 4B][0x00]
```

Payload je podľa `xfcp_tx_packetizer.sv` MSB-first, takže readback skladáš takto:

```systemverilog
task automatic xfcp_recv_read(output logic [31:0] rdata);
  logic [7:0] b;

  // header: 20 bytes
  for (int i = 0; i < 20; i++) begin
    uart_recv(b);
  end

  // payload MSB-first
  uart_recv(b); rdata[31:24] = b;
  uart_recv(b); rdata[23:16] = b;
  uart_recv(b); rdata[15:8]  = b;
  uart_recv(b); rdata[7:0]   = b;

  // final terminator byte
  uart_recv(b);
endtask
```

## 6. Pozor na duplicitný `xfcp_axil_bridge`

Máš dva súbory:

```text
xfcp_axil_bridge.sv
xfcp_axil_bridge_2.sv
```

Oba deklarujú modul:

```systemverilog
module xfcp_axil_bridge
```

a oba používajú rovnaký include guard:

```systemverilog
`ifndef XFCP_AXIL_BRIDGE
```

Do buildu dávaj iba jeden z nich. Odporúčam ponechať `xfcp_axil_bridge_2.sv` ako aktuálnejšiu verziu, ale premenovať súbor späť na:

```text
xfcp_axil_bridge.sv
```

a starý odstrániť alebo presunúť mimo compile list.

## 7. Moje odporúčané poradie teraz

1. **Rozhodni sa pre nový protokol**: `0xFE`, `WRITE=0x11`, header `[SOP][OP][COUNT][ADDR]`.
2. V `xfcp_uart_mmio_top.sv` nahraď `axil_xfcp_mod` za `xfcp_axil_bridge`.
3. Medzi `axis_uart_rx` a `xfcp_rx_parser` zruš per-byte TLAST, teda daj do bridge `TLAST=0`.
4. Uprav TB helpery na nový packet format.
5. V TB pridaj timeout do `uart_recv()`, aby simulácia nevisela potichu:

```systemverilog
task automatic uart_recv(output logic [7:0] b);
  int timeout;
  timeout = 0;
  while (rx_rptr == rx_wptr) begin
    @(posedge clk);
    timeout++;
    if (timeout > 20000) begin
      $fatal(1, "UART RX timeout waiting for DUT response");
    end
  end
  b = rx_buf[rx_rptr & 31];
  rx_rptr++;
endtask
```

Najbližší konkrétny krok: **uprav top na nový `xfcp_axil_bridge` + uprav TB protokol + vypni TLAST z UART RX do parsera**. Potom by sa prvý test mal buď rozbehnúť, alebo aspoň skončiť jasným timeoutom namiesto tichého `run -all` hang-u.
