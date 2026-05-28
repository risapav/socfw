/**
 * @file        udp_tx_stream_to_ram.sv
 * @brief       Most medzi byte-streaming UDP TX vystupom echo modulu a TX RAM pre ipsend.
 * @details     Prijima bajty z echo modulu (AXI-stream s handshake), pakuje ich do 32-bit
 *              slov MSB-first a zapisuje do TX RAM od adresy 1 (ipsend cita od adresy 1).
 *              Po prichode posledneho bajtu (last_i) zapise ostatne slovo (moze byt
 *              ciastocne, zvysok je nulovy) a vyda 1-cyklovy pulz tx_start_o pre ipsend.
 *
 *              Backpressure: ready_o = 0 pokym ipsend vysiela (tx_busy_i = 1) alebo
 *              kym start_i nepride. Echo modul stoji v ST_SEND_PAY kym ready_i = 0.
 *
 * @param       (ziadne)
 */
`ifndef UDP_TX_STREAM_TO_RAM_SV
`define UDP_TX_STREAM_TO_RAM_SV

`default_nettype none

module udp_tx_stream_to_ram (
  input  wire         clk_i,
  input  wire         rst_ni,

  // Spustenie od top-level: pulz = metadata zachytene, mozeme prijmat payload
  input  wire         start_i,

  // Echo modul TX payload stream
  input  wire         valid_i,
  output logic        ready_o,
  input  wire [7:0]   data_i,
  input  wire         last_i,

  // TX RAM zapisovy port (zapis od adresy 1, MSB-first packing)
  output logic [8:0]  ram_wr_addr_o,
  output logic [31:0] ram_wr_data_o,
  output logic        ram_wr_we_o,

  // ipsend riadiace vystupy
  output logic        tx_start_o,          // 1-cyklovy pulz: zacni vysilat
  output logic [15:0] tx_data_length_o,    // UDP payload + 8 (pre ipsend)
  output logic [15:0] tx_total_length_o,   // UDP payload + 28 (pre ipsend)

  // Stav pre top-level
  output logic        idle_o,              // 1 = pripraveny na novu meta handshake

  // ipsend zaneprazdnenost (0 = volny, 1 = vysiela)
  input  wire         tx_busy_i
);

  typedef enum logic [1:0] {
    ST_IDLE    = 2'd0,
    ST_RECV    = 2'd1,
    ST_TRIGGER = 2'd2
  } state_e;

  state_e state_q;

  logic [8:0]  word_addr_q;   // aktualny adresa zapisu do RAM (zacina na 1)
  logic [1:0]  byte_cnt_q;    // pocet bajtov v aktualnom slove (0-3)
  logic [31:0] buf_q;          // akumulacny buffer pre 4 bajty
  logic [15:0] byte_total_q;  // celkovy pocet zapiasnych bajtov

  // Packing: novy bajt do prislusnej pozicie v buf_q (MSB-first)
  logic [31:0] buf_next_w;

  always_comb begin
    buf_next_w = buf_q;
    case (byte_cnt_q)
      2'd0: buf_next_w[31:24] = data_i;
      2'd1: buf_next_w[23:16] = data_i;
      2'd2: buf_next_w[15:8]  = data_i;
      2'd3: buf_next_w[7:0]   = data_i;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_IDLE;
      word_addr_q  <= 9'd1;
      byte_cnt_q   <= 2'd0;
      buf_q        <= 32'd0;
      byte_total_q <= 16'd0;
      ram_wr_addr_o <= 9'd0;
      ram_wr_data_o <= 32'd0;
      ram_wr_we_o   <= 1'b0;
      tx_start_o        <= 1'b0;
      tx_data_length_o  <= 16'd0;
      tx_total_length_o <= 16'd0;
    end else begin
      // Defaulty
      ram_wr_we_o <= 1'b0;
      tx_start_o  <= 1'b0;

      case (state_q)

        ST_IDLE: begin
          if (start_i) begin
            word_addr_q  <= 9'd1;
            byte_cnt_q   <= 2'd0;
            buf_q        <= 32'd0;
            byte_total_q <= 16'd0;
            state_q      <= ST_RECV;
          end
        end

        ST_RECV: begin
          if (valid_i) begin
            byte_total_q <= byte_total_q + 16'd1;
            if (last_i || byte_cnt_q == 2'd3) begin
              // Uloz aktualne slovo do RAM
              ram_wr_addr_o <= word_addr_q;
              ram_wr_data_o <= buf_next_w;
              ram_wr_we_o   <= 1'b1;
              word_addr_q   <= word_addr_q + 1'b1;
              buf_q         <= 32'd0;
              byte_cnt_q    <= 2'd0;
              if (last_i) begin
                tx_data_length_o  <= byte_total_q + 16'd9;   // payload + 1 + 8 (UDP hdr)
                tx_total_length_o <= byte_total_q + 16'd29;  // payload + 1 + 28 (IP+UDP)
                state_q           <= ST_TRIGGER;
              end
            end else begin
              buf_q      <= buf_next_w;
              byte_cnt_q <= byte_cnt_q + 2'd1;
            end
          end
        end

        ST_TRIGGER: begin
          tx_start_o <= 1'b1;
          state_q    <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Kombinacne vystupy
  // ---------------------------------------------------------------------------
  assign ready_o = (state_q == ST_RECV);
  assign idle_o  = (state_q == ST_IDLE) && !tx_busy_i;
  // tx_data_length_o and tx_total_length_o are registered in always_ff above

endmodule

`endif // UDP_TX_STREAM_TO_RAM_SV
