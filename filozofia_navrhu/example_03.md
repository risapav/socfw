Skontrolované. Topológia je správna:

```text
picture_gen_stream → video_stream_fifo → video_stream_frame_sync → vga_rgb565_stream
```

ale treba opraviť tieto veci:

## Kritické opravy

### 1. `picture_gen_stream` má zle zarovnaný `SOF`

Aktuálne môže prvý pixel ísť s `sof=0` a ďalší cyklus znova s `sof=1`. Nahraď registrovaný výstupný blok týmto kombinačným výstupom:

```systemverilog
assign m_axis_data_o = data_next;
assign m_axis_sof_o  = m_axis_valid_o && (x_q == '0) && (y_q == '0);
assign m_axis_eol_o  = m_axis_valid_o && last_x;
assign m_axis_eof_o  = m_axis_valid_o && last_pixel;
```

A zmaž tento blok:

```systemverilog
always_ff @(posedge clk_i) begin
    ...
end
```

ktorý registruje `m_axis_data_o`, `m_axis_sof_o`, `m_axis_eol_o`, `m_axis_eof_o`.

---

### 2. `frame_sync` nesmie používať registrované VGA výstupy

V `vga_rgb565_stream` pridaj nové výstupy:

```systemverilog
output logic stream_active_o,
output logic stream_frame_start_o,
```

a priraď ich kombinačne:

```systemverilog
assign stream_active_o      = active_video;
assign stream_frame_start_o = first_active_pixel;
```

V tope potom použi tieto nové signály pre `vsync0`:

```systemverilog
.video_active_i(w_vga0_stream_active),
.video_frame_start_i(w_vga0_stream_frame_start)
```

Nie:

```systemverilog
.video_active_i(w_vga0_active_video_o),
.video_frame_start_i(w_vga0_frame_start_o)
```

Tie sú registrované a posunuté o 1 takt.

---

### 3. Reset musí čakať na PLL locked, ale PLL nesmie resetovať sám seba

V tope nepoužívaj:

```systemverilog
assign reset_n = RESET_N;
```

Lepšie:

```systemverilog
wire pll_reset;
logic [2:0] reset_sync;

assign pll_reset = ~RESET_N;

always_ff @(posedge clkpll_c0 or negedge RESET_N) begin
    if (!RESET_N)
        reset_sync <= 3'b000;
    else
        reset_sync <= {reset_sync[1:0], w_clkpll_locked};
end

assign reset_n = reset_sync[2];
```

PLL nechaj takto:

```systemverilog
clkpll clkpll (
    .areset(pll_reset),
    .c0(clkpll_c0),
    .inclk0(SYS_CLK),
    .locked(w_clkpll_locked)
);
```

---

## Odporúčaná malá zmena

V `pgen0` nastav:

```systemverilog
.continuous_i(1'b1),
.start_i(w_clkpll_locked),
```

Teraz máš `continuous_i(1'b0)`, ale `start_i` je trvalo `1`, takže sa generátor po každom frame aj tak znova spustí. S `continuous_i(1'b1)` je to čistejšie.

---

## Verdikt

Hlavný dôvod možného posunu obrazu je teraz:

```text
picture_gen_stream má oneskorený SOF
+
frame_sync dostáva oneskorený frame_start z VGA
```

Po oprave týchto dvoch bodov by sa kríž mal stabilne zobraziť v strede.
