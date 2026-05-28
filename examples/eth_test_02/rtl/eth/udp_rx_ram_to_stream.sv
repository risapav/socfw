/**
 * @file        udp_rx_ram_to_stream.sv
 * @brief       Most medzi ipreceive RAM vystupom a byte-streaming UDP interfacom.
 * @details     Po prichode data_receive_i pulzu (rx_clk domena) synchronizuje signal
 *              do tx_clk domeny, zachyti metadata a potom cita prijaté data z RX RAM
 *              po slovach (32b) a streamuje ich bajt po bajte do echo modulu.
 *
 *              CDC: data_receive_i (1-cyklovy pulz v rx_clk) sa prenasa cez toggle +
 *              cdc_two_flop_synchronizer do tx_clk. Metadata signaly (pc_ip_i, atd.)
 *              su stabilne dlho po data_receive_i, takze ich mozno latcovat v tx_clk
 *              po prichode synchronizovaneho hrany.
 *
 *              RAM latencia: ram.sv ma 2-registrovu latenciu. Adapter prezentuje adresu
 *              v ST_LOAD_W (kombinacne), caka 2 cykly v ST_RD_WAIT, pak latchuje slovo.
 *
 * @param       (ziadne)
 */
`ifndef UDP_RX_RAM_TO_STREAM_SV
`define UDP_RX_RAM_TO_STREAM_SV

`default_nettype none

module udp_rx_ram_to_stream (
  // RX clock domain (ipreceive)
  input  wire         rx_clk_i,
  input  wire         rst_ni,
  input  wire         data_receive_i,      // 1-cycle pulse — cely ramec priaty
  input  wire [31:0]  pc_ip_i,             // zdrojova IP (PC) — stabilna po data_receive_i
  input  wire [31:0]  board_ip_i,          // cielova IP (board) — stabilna po data_receive_i
  input  wire [63:0]  udp_layer_i,         // {src_port,dst_port,udp_len,udp_csum} — stabilna
  input  wire [15:0]  rx_data_length_i,    // UDP dlzka (payload + 8 UDP hlavicka bajtov)

  // TX clock domain
  input  wire         tx_clk_i,

  // RX RAM ctaci port (tx_clk domena — po synchronizacii je zapis uz hotovy)
  output logic [8:0]  ram_addr_o,
  input  wire [31:0]  ram_data_i,

  // UDP RX metadata pre echo modul (tx_clk domena)
  output logic        udp_rx_meta_valid_o,
  input  wire         udp_rx_meta_ready_i,
  output logic [31:0] udp_rx_src_ip_o,
  output logic [31:0] udp_rx_dst_ip_o,
  output logic [15:0] udp_rx_src_port_o,
  output logic [15:0] udp_rx_dst_port_o,
  output logic [15:0] udp_rx_length_o,

  // UDP RX payload stream pre echo modul (tx_clk domena)
  output logic        udp_rx_valid_o,
  input  wire         udp_rx_ready_i,
  output logic [7:0]  udp_rx_data_o,
  output logic        udp_rx_last_o
);

  // ---------------------------------------------------------------------------
  // CDC: toggle synchronizacia data_receive_i (rx_clk) -> tx_clk
  // ---------------------------------------------------------------------------
  logic rx_tog_q;

  always_ff @(posedge rx_clk_i or negedge rst_ni) begin
    if (!rst_ni) rx_tog_q <= 1'b0;
    else if (data_receive_i) rx_tog_q <= ~rx_tog_q;
  end

  logic rx_tog_sync_w;

  cdc_two_flop_synchronizer #(.WIDTH(1)) u_rx_cdc (
    .clk_i  (tx_clk_i),
    .rst_ni (rst_ni),
    .d_i    (rx_tog_q),
    .q_o    (rx_tog_sync_w)
  );

  logic rx_tog_prev_q;
  logic rx_pulse_w;

  always_ff @(posedge tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) rx_tog_prev_q <= 1'b0;
    else         rx_tog_prev_q <= rx_tog_sync_w;
  end

  assign rx_pulse_w = rx_tog_sync_w ^ rx_tog_prev_q;

  // ---------------------------------------------------------------------------
  // FSM (tx_clk domena)
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE    = 3'd0,
    ST_META    = 3'd1,
    ST_LOAD_W  = 3'd2,
    ST_RD_WAIT = 3'd3,
    ST_STREAM  = 3'd4,
    ST_DONE    = 3'd5
  } state_e;

  state_e state_q;

  // Latched metadata (tx_clk domain)
  logic [31:0] src_ip_q;
  logic [31:0] dst_ip_q;
  logic [15:0] src_port_q;
  logic [15:0] dst_port_q;
  logic [15:0] payload_len_q;   // actual payload bytes = rx_data_length_i - 8

  // RAM streaming state
  logic [8:0]  word_addr_q;
  logic        wait_cnt_q;
  logic [31:0] cur_word_q;
  logic [1:0]  byte_sel_q;
  logic [15:0] bytes_rem_q;

  always_ff @(posedge tx_clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q       <= ST_IDLE;
      src_ip_q      <= 32'd0;
      dst_ip_q      <= 32'd0;
      src_port_q    <= 16'd0;
      dst_port_q    <= 16'd0;
      payload_len_q <= 16'd0;
      word_addr_q   <= 9'd0;
      wait_cnt_q    <= 1'b0;
      cur_word_q    <= 32'd0;
      byte_sel_q    <= 2'd0;
      bytes_rem_q   <= 16'd0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (rx_pulse_w) begin
            // Metadata su stabilne – latcuj v tx_clk domene
            src_ip_q      <= pc_ip_i;
            dst_ip_q      <= board_ip_i;
            src_port_q    <= udp_layer_i[63:48];
            dst_port_q    <= udp_layer_i[47:32];
            // rx_data_length_i = UDP dlzka (payload + 8 header bajtov)
            payload_len_q <= rx_data_length_i - 16'd8;
            state_q       <= ST_META;
          end
        end

        ST_META: begin
          // Cakame na pripravenost echo modulu prijat metadata
          if (udp_rx_meta_ready_i) begin
            word_addr_q <= 9'd1;  // ipreceive writes payload from addr 1 (addr 0 skipped)
            byte_sel_q  <= 2'd0;
            bytes_rem_q <= payload_len_q;
            wait_cnt_q  <= 1'b0;
            state_q     <= ST_LOAD_W;
          end
        end

        ST_LOAD_W: begin
          // Adresa je kombinacne nastavena (ram_addr_o = word_addr_q)
          // RAM zachyti read_data_q <- mem[word_addr_q] na tejto hrane
          wait_cnt_q <= 1'b0;
          state_q    <= ST_RD_WAIT;
        end

        ST_RD_WAIT: begin
          if (wait_cnt_q == 1'b0) begin
            // 2. hrana: RAM prida data_o <- read_data_q — data bude platne medzi tymito dvoma hranami
            wait_cnt_q <= 1'b1;
          end else begin
            // 3. hrana: latchujeme platne ram_data_i
            cur_word_q <= ram_data_i;
            state_q    <= ST_STREAM;
          end
        end

        ST_STREAM: begin
          if (udp_rx_ready_i) begin
            if (bytes_rem_q == 16'd1) begin
              // Posledny bajt — prejdeme na ST_DONE
              bytes_rem_q <= 16'd0;
              state_q     <= ST_DONE;
            end else begin
              bytes_rem_q <= bytes_rem_q - 16'd1;
              if (byte_sel_q == 2'd3) begin
                // Dosli sme na koniec slova — nacitat nasledujuce
                byte_sel_q  <= 2'd0;
                word_addr_q <= word_addr_q + 1'b1;
                wait_cnt_q  <= 1'b0;
                state_q     <= ST_LOAD_W;
              end else begin
                byte_sel_q <= byte_sel_q + 1'b1;
              end
            end
          end
        end

        ST_DONE: begin
          state_q <= ST_IDLE;
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Kombinacne vystupy
  // ---------------------------------------------------------------------------

  // RAM adresa: platna pocas ST_LOAD_W aj ST_RD_WAIT (drz stabilnu adresu)
  always_comb begin
    if (state_q == ST_LOAD_W || state_q == ST_RD_WAIT)
      ram_addr_o = word_addr_q;
    else
      ram_addr_o = 9'd0;
  end

  // Metadata pre echo modul
  assign udp_rx_meta_valid_o = (state_q == ST_META);
  assign udp_rx_src_ip_o     = src_ip_q;
  assign udp_rx_dst_ip_o     = dst_ip_q;
  assign udp_rx_src_port_o   = src_port_q;
  assign udp_rx_dst_port_o   = dst_port_q;
  assign udp_rx_length_o     = payload_len_q;

  // Payload stream
  assign udp_rx_valid_o = (state_q == ST_STREAM);
  assign udp_rx_last_o  = (state_q == ST_STREAM) && (bytes_rem_q == 16'd1);

  always_comb begin
    case (byte_sel_q)
      2'd0:    udp_rx_data_o = cur_word_q[31:24];
      2'd1:    udp_rx_data_o = cur_word_q[23:16];
      2'd2:    udp_rx_data_o = cur_word_q[15:8];
      default: udp_rx_data_o = cur_word_q[7:0];
    endcase
  end

endmodule

`endif // UDP_RX_RAM_TO_STREAM_SV
