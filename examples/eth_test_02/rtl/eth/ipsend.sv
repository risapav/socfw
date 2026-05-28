/**
 * @file        ipsend.sv
 * @brief       GMII UDP vysielaci modul s dynamickymi IP/port vstupmi.
 * @details     Zostavuje a vysiela MAC, IP, UDP hlavicky a CRC32.
 *              Rozsirenie oprot eth_test: dynamicke src/dst IP a porty,
 *              tx_start_i pre okamzite spustenie (echo rezim),
 *              timer_en_i pre volitelne periodicke vysielanie.
 */
`default_nettype none
`ifndef IP_SEND_SV
`define IP_SEND_SV

module ipsend (
  input  wire         clk_i,
  input  wire         rst_ni,
  output logic        tx_en_o,
  output logic        tx_er_o,
  output logic [7:0]  tx_data_o,
  input  wire  [31:0] crc_i,
  input  wire  [31:0] ram_rd_data_i,
  output logic        crc_en_o,
  output logic        crc_rst_no,
  output logic [3:0]  tx_state_o,
  input  wire  [15:0] tx_data_length_i,
  input  wire  [15:0] tx_total_length_i,
  output logic [8:0]  ram_rd_addr_o,
  // Dynamic IP/port metadata
  input  wire  [31:0] tx_src_ip_i,
  input  wire  [31:0] tx_dst_ip_i,
  input  wire  [15:0] tx_src_port_i,
  input  wire  [15:0] tx_dst_port_i,
  // Trigger: 1-cycle pulse = start immediately (bypass timer)
  input  wire         tx_start_i,
  // Timer enable: 0 = periodic timer disabled (echo-only mode)
  input  wire         timer_en_i
);

  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,
    ST_START      = 4'd1,
    ST_MAKE       = 4'd2,
    ST_SEND_55    = 4'd3,
    ST_SEND_MAC   = 4'd4,
    ST_SEND_HEAD  = 4'd5,
    ST_SEND_DATA  = 4'd6,
    ST_SEND_PAD   = 4'd7,
    ST_SEND_CRC   = 4'd8
  } tx_state_e;

  tx_state_e state_q;
  assign tx_state_o = state_q;

  localparam logic [7:0] PREAMBLE [0:7] = '{
    8'h55, 8'h55, 8'h55, 8'h55,
    8'h55, 8'h55, 8'h55, 8'hD5
  };

  localparam logic [7:0] MAC_ADDR [0:13] = '{
    8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF,
    8'h00, 8'h0A, 8'h35, 8'h01, 8'hFE, 8'hC0,
    8'h08, 8'h00
  };

  logic [31:0] datain_q;
  logic [31:0] crc_hold_q;
  logic [31:0] ip_header_q [7];
  logic [31:0] ip_cur_word_q;  // registered: ip_header_q[j_cnt_q], breaks mux->tx_data path
  logic [17:0] csum_part0_q;
  logic [17:0] csum_part1_q;
  logic [16:0] csum_part2_q;
  logic [4:0]  i_cnt_q;
  logic [4:0]  j_cnt_q;
  logic [31:0] check_buffer_q;
  logic [31:0] time_counter_q;
  logic [15:0] tx_data_counter_q;
  logic [5:0]  pad_len_q;
  logic [5:0]  pad_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= ST_IDLE;
      tx_en_o           <= 1'b0;
      tx_er_o           <= 1'b0;
      tx_data_o         <= 8'd0;
      crc_en_o          <= 1'b0;
      crc_rst_no        <= 1'b0;
      ram_rd_addr_o     <= 9'd0;
      i_cnt_q           <= 5'd0;
      j_cnt_q           <= 5'd0;
      tx_data_counter_q <= 16'd0;
      time_counter_q    <= 32'd0;
      check_buffer_q    <= 32'd0;
      pad_len_q         <= 6'd0;
      pad_cnt_q         <= 6'd0;
      csum_part0_q      <= '0;
      csum_part1_q      <= '0;
      csum_part2_q      <= '0;
      datain_q          <= 32'd0;
      crc_hold_q        <= 32'd0;
      ip_cur_word_q     <= 32'd0;

      for (int k = 0; k < 7; k++) ip_header_q[k] <= 32'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          tx_er_o           <= 1'b0;
          tx_en_o           <= 1'b0;
          crc_en_o          <= 1'b0;
          crc_rst_no        <= 1'b0;
          j_cnt_q           <= 5'd0;
          tx_data_o         <= 8'd0;
          ram_rd_addr_o     <= 9'd1;
          tx_data_counter_q <= 16'd0;
          if ((time_counter_q == 32'h04000000 && timer_en_i) || tx_start_i) begin
            state_q        <= ST_START;
            time_counter_q <= 32'd0;
          end else begin
            time_counter_q <= time_counter_q + 1'b1;
          end
        end

        ST_START: begin
          ip_header_q[0] <= {16'h4500, tx_total_length_i};
          ip_header_q[1][31:16] <= ip_header_q[1][31:16] + 1'b1;
          ip_header_q[1][15:0]  <= 16'h4000;
          ip_header_q[2] <= 32'h80110000;   // TTL=128, UDP, checksum=0 (computed in ST_MAKE)
          ip_header_q[3] <= tx_src_ip_i;
          ip_header_q[4] <= tx_dst_ip_i;
          ip_header_q[5] <= {tx_src_port_i, tx_dst_port_i};
          ip_header_q[6] <= {tx_data_length_i, 16'h0000};
          // Ethernet minimum: 14 MAC + ip_total >= 60, pad = max(0, 46 - ip_total)
          pad_len_q      <= (tx_total_length_i < 16'd46) ?
                            6'(16'd46 - tx_total_length_i) : 6'd0;
          state_q        <= ST_MAKE;
        end

        ST_MAKE: begin
          if (i_cnt_q == 5'd0) begin
            csum_part0_q <= {2'b0, ip_header_q[0][15:0]} + {2'b0, ip_header_q[0][31:16]}
                          + {2'b0, ip_header_q[1][15:0]} + {2'b0, ip_header_q[1][31:16]};
            i_cnt_q <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd1) begin
            csum_part1_q <= {2'b0, ip_header_q[2][15:0]} + {2'b0, ip_header_q[2][31:16]}
                          + {2'b0, ip_header_q[3][15:0]} + {2'b0, ip_header_q[3][31:16]};
            i_cnt_q <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd2) begin
            csum_part2_q <= {1'b0, ip_header_q[4][15:0]} + {1'b0, ip_header_q[4][31:16]};
            i_cnt_q <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd3) begin
            check_buffer_q <= {14'b0, csum_part0_q} + {14'b0, csum_part1_q}
                            + {15'b0, csum_part2_q};
            i_cnt_q <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd4) begin
            check_buffer_q[15:0] <= check_buffer_q[31:16] + check_buffer_q[15:0];
            i_cnt_q <= i_cnt_q + 1'b1;
          end else begin
            ip_header_q[2][15:0] <= ~check_buffer_q[15:0];
            i_cnt_q <= 5'd0;
            state_q <= ST_SEND_55;
          end
        end

        ST_SEND_55: begin
          tx_en_o    <= 1'b1;
          crc_rst_no <= 1'b0;
          if (i_cnt_q == 5'd7) begin
            tx_data_o <= PREAMBLE[i_cnt_q[2:0]];
            i_cnt_q   <= 5'd0;
            state_q   <= ST_SEND_MAC;
          end else begin
            tx_data_o <= PREAMBLE[i_cnt_q[2:0]];
            i_cnt_q   <= i_cnt_q + 1'b1;
          end
        end

        ST_SEND_MAC: begin
          crc_en_o   <= 1'b1;
          crc_rst_no <= 1'b1;
          if (i_cnt_q == 5'd13) begin
            tx_data_o     <= MAC_ADDR[i_cnt_q[3:0]];
            ip_cur_word_q <= ip_header_q[0];
            i_cnt_q       <= 5'd0;
            state_q       <= ST_SEND_HEAD;
          end else begin
            tx_data_o <= MAC_ADDR[i_cnt_q[3:0]];
            i_cnt_q   <= i_cnt_q + 1'b1;
          end
        end

        ST_SEND_HEAD: begin
          datain_q <= ram_rd_data_i;
          if (j_cnt_q == 5'd6) begin
            if (i_cnt_q == 5'd0) begin
              tx_data_o <= ip_cur_word_q[31:24];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd1) begin
              tx_data_o <= ip_cur_word_q[23:16];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd2) begin
              tx_data_o <= ip_cur_word_q[15:8];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd3) begin
              tx_data_o <= ip_cur_word_q[7:0];
              i_cnt_q   <= 5'd0;
              j_cnt_q   <= 5'd0;
              state_q   <= ST_SEND_DATA;
            end else begin
              tx_er_o <= 1'b1;
            end
          end else begin
            if (i_cnt_q == 5'd0) begin
              tx_data_o <= ip_cur_word_q[31:24];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd1) begin
              tx_data_o <= ip_cur_word_q[23:16];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd2) begin
              tx_data_o <= ip_cur_word_q[15:8];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd3) begin
              tx_data_o     <= ip_cur_word_q[7:0];
              ip_cur_word_q <= ip_header_q[j_cnt_q[2:0] + 1'b1];
              i_cnt_q       <= 5'd0;
              j_cnt_q       <= j_cnt_q + 1'b1;
            end else begin
              tx_er_o <= 1'b1;
            end
          end
        end

        ST_SEND_DATA: begin
          if (tx_data_counter_q == (tx_data_length_i - 16'd9)) begin
            if (pad_len_q != 6'd0)
              state_q <= ST_SEND_PAD;
            else
              state_q <= ST_SEND_CRC;
            if (i_cnt_q == 5'd0) begin
              tx_data_o <= datain_q[31:24];
              i_cnt_q   <= 5'd0;
            end else if (i_cnt_q == 5'd1) begin
              tx_data_o <= datain_q[23:16];
              i_cnt_q   <= 5'd0;
            end else if (i_cnt_q == 5'd2) begin
              tx_data_o <= datain_q[15:8];
              i_cnt_q   <= 5'd0;
            end else if (i_cnt_q == 5'd3) begin
              tx_data_o <= datain_q[7:0];
              datain_q  <= ram_rd_data_i;
              i_cnt_q   <= 5'd0;
            end
          end else begin
            tx_data_counter_q <= tx_data_counter_q + 1'b1;
            if (i_cnt_q == 5'd0) begin
              tx_data_o     <= datain_q[31:24];
              i_cnt_q       <= i_cnt_q + 1'b1;
              ram_rd_addr_o <= ram_rd_addr_o + 1'b1;
            end else if (i_cnt_q == 5'd1) begin
              tx_data_o <= datain_q[23:16];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd2) begin
              tx_data_o <= datain_q[15:8];
              i_cnt_q   <= i_cnt_q + 1'b1;
            end else if (i_cnt_q == 5'd3) begin
              tx_data_o <= datain_q[7:0];
              datain_q  <= ram_rd_data_i;
              i_cnt_q   <= 5'd0;
            end
          end
        end

        ST_SEND_PAD: begin
          tx_data_o <= 8'h00;
          crc_en_o  <= 1'b1;
          if (pad_cnt_q == pad_len_q - 1'b1) begin
            pad_cnt_q <= 6'd0;
            state_q   <= ST_SEND_CRC;
          end else begin
            pad_cnt_q <= pad_cnt_q + 1'b1;
          end
        end

        ST_SEND_CRC: begin
          crc_en_o <= 1'b0;
          if (i_cnt_q == 5'd0) begin
            crc_hold_q <= crc_i;
            tx_data_o  <= ~crc_i[7:0];
            i_cnt_q    <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd1) begin
            tx_data_o <= ~crc_hold_q[15:8];
            i_cnt_q   <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd2) begin
            tx_data_o <= ~crc_hold_q[23:16];
            i_cnt_q   <= i_cnt_q + 1'b1;
          end else if (i_cnt_q == 5'd3) begin
            tx_data_o <= ~crc_hold_q[31:24];
            i_cnt_q   <= 5'd0;
            state_q   <= ST_IDLE;
          end else begin
            tx_er_o <= 1'b1;
          end
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

endmodule

`endif // IP_SEND_SV
