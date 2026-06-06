/**
 * @file udp_echo.sv
 * @brief UDP echo: parses UDP header, buffers payload, generates echo reply.
 * @param MAX_DATA_BYTES  Maximum UDP payload bytes buffered (default 1472).
 * @details Receives IPv4 payload stream from ipv4_rx (proto=0x11 = UDP).
 *   Activates on s_ip_hdr_valid_i with proto=UDP and accept=1.
 *   Byte 0 of UDP stream (src_port MSB) arrives simultaneously with hdr_valid.
 *
 *   UDP header layout (8 bytes):
 *     [0:1] src_port   [2:3] dst_port
 *     [4:5] udp_len    [6:7] checksum (ignored)
 *
 *   Filters: if !promiscuous_i, only accepts frames targeting local_port_i.
 *   Reply: swaps src/dst ports, same udp_len, checksum=0x0000 (RFC 768 optional).
 *
 *   Output to ipv4_tx: meta (proto=UDP, dst_ip, dst_mac, payload_len=udp_len)
 *   and stream (8-byte UDP reply header + payload data).
 *
 *   No backpressure upstream (accepts bytes at full rate).
 *   One frame at a time: new frames dropped while TX pending (req_valid_q=1).
 *
 *   TX data RAM read is pipelined: tx_rd_addr_q runs 1 cycle ahead of tx_out_cnt_q,
 *   and the udp_data_mem read is registered (M9K outdata_reg). This breaks the
 *   portb_address_reg0 -> m_axis_tdata_o timing bottleneck.
 */
`ifndef UDP_ECHO_SV
`define UDP_ECHO_SV

`default_nettype none

module udp_echo #(
  parameter int MAX_DATA_BYTES = 1472
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- Configuration ----
  input  wire logic [15:0] local_port_i,
  input  wire logic        promiscuous_i,

  // ---- Source MAC (stable for entire frame, from top-level latch) ----
  input  wire logic [47:0] s_eth_src_mac_i,

  // ---- ipv4_rx early header (registered 1-cycle pulse) ----
  input  wire logic        s_ip_hdr_valid_i,
  input  wire logic [7:0]  s_ip_proto_i,
  input  wire logic [31:0] s_ip_src_ip_i,
  input  wire logic        s_ip_accept_i,

  // ---- IPv4 payload stream (no backpressure) ----
  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  input  wire logic        s_axis_tlast,
  input  wire logic        s_axis_tuser,

  // ---- Metadata to ipv4_tx ----
  output      logic        m_meta_valid_o,
  input  wire logic        m_meta_ready_i,
  output      logic [7:0]  m_meta_proto_o,
  output      logic [31:0] m_meta_dst_ip_o,
  output      logic [47:0] m_meta_dst_mac_o,
  output      logic [15:0] m_meta_payload_len_o,  // = udp_len (8B hdr + data)

  // ---- Payload stream to ipv4_tx (with backpressure) ----
  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o,

  // ---- Diagnostics ----
  output      logic [15:0] stat_rx_frames,
  output      logic [15:0] stat_tx_frames
);

  // -------------------------------------------------------------------------
  // RX FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    RX_IDLE  = 3'd0,
    RX_HDR   = 3'd1,  // parse 8-byte UDP header
    RX_DATA  = 3'd2,  // buffer data bytes
    RX_DRAIN = 3'd3   // drain rejected frame
  } rx_state_e;

  // TX FSM
  typedef enum logic [2:0] {
    TX_IDLE  = 3'd0,
    TX_META  = 3'd1,
    TX_HDR   = 3'd2,  // send 8-byte UDP reply header
    TX_DATA  = 3'd3
  } tx_state_e;

  rx_state_e rx_state_q;
  tx_state_e tx_state_q;

  // RX registers (UDP header capture)
  logic [2:0]  rx_byte_cnt_q;
  logic [7:0]  src_b0_q, src_b1_q;    // bytes 0-1: source port
  logic [7:0]  dst_b0_q, dst_b1_q;    // bytes 2-3: dest port
  logic [7:0]  len_b0_q, len_b1_q;    // bytes 4-5: udp_len
  logic        drop_q;
  logic        port_ok_q;
  logic [47:0] src_mac_q;
  logic [31:0] src_ip_q;
  logic [15:0] rx_data_cnt_q;

  // TX registers
  logic [47:0] tx_dst_mac_q;
  logic [31:0] tx_dst_ip_q;
  logic [15:0] tx_udp_len_q;
  logic [15:0] tx_data_len_q;
  logic [2:0]  tx_hdr_cnt_q;
  // tx_rd_addr_q: read pointer into udp_data_mem, runs 1 cycle ahead of output
  logic [15:0] tx_rd_addr_q;
  // tx_out_cnt_q: tracks which output byte is on the wire (for tlast)
  logic [15:0] tx_out_cnt_q;

  logic [7:0]  tx_src_b0_q, tx_src_b1_q;
  logic [7:0]  tx_dst_b0_q, tx_dst_b1_q;

  logic req_valid_q;

  logic [15:0] cnt_rx_q;
  logic [15:0] cnt_tx_q;

  // UDP data buffer: registered read breaks portb_address_reg0 timing path
  (* ramstyle = "M9K" *) logic [7:0] udp_data_mem [0:MAX_DATA_BYTES-1];

  // -------------------------------------------------------------------------
  // Data memory write
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rx_state_q == RX_DATA && s_axis_tvalid &&
        (rx_data_cnt_q < 16'(MAX_DATA_BYTES))) begin
      udp_data_mem[rx_data_cnt_q[$clog2(MAX_DATA_BYTES)-1:0]] <= s_axis_tdata;
    end
  end

  // Registered read: tx_rd_addr_q runs 1 cycle ahead so data is ready on time.
  logic [7:0] tx_data_byte_q;
  always_ff @(posedge clk_i) begin
    tx_data_byte_q <= udp_data_mem[tx_rd_addr_q[$clog2(MAX_DATA_BYTES)-1:0]];
  end

  // TX fire signal
  logic tx_fire_w;
  assign tx_fire_w = m_axis_tvalid_o && m_axis_tready_i;

  // TX header ROM (8 bytes): echo reply swaps src/dst ports, same len, csum=0
  logic [7:0] tx_hdr_byte_w;
  always_comb begin
    case (tx_hdr_cnt_q)
      3'd0:    tx_hdr_byte_w = tx_dst_b0_q;
      3'd1:    tx_hdr_byte_w = tx_dst_b1_q;
      3'd2:    tx_hdr_byte_w = tx_src_b0_q;
      3'd3:    tx_hdr_byte_w = tx_src_b1_q;
      3'd4:    tx_hdr_byte_w = tx_udp_len_q[15:8];
      3'd5:    tx_hdr_byte_w = tx_udp_len_q[7:0];
      3'd6:    tx_hdr_byte_w = 8'h00;
      3'd7:    tx_hdr_byte_w = 8'h00;
      default: tx_hdr_byte_w = 8'h00;
    endcase
  end

  // -------------------------------------------------------------------------
  // Combined RX + TX FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q    <= RX_IDLE;
      tx_state_q    <= TX_IDLE;
      rx_byte_cnt_q <= 3'd0;
      src_b0_q      <= 8'h00; src_b1_q <= 8'h00;
      dst_b0_q      <= 8'h00; dst_b1_q <= 8'h00;
      len_b0_q      <= 8'h00; len_b1_q <= 8'h00;
      drop_q        <= 1'b0;
      port_ok_q     <= 1'b0;
      src_mac_q     <= '0;
      src_ip_q      <= '0;
      rx_data_cnt_q <= 16'd0;
      tx_dst_mac_q  <= '0;
      tx_dst_ip_q   <= '0;
      tx_udp_len_q  <= 16'd0;
      tx_data_len_q <= 16'd0;
      tx_hdr_cnt_q  <= 3'd0;
      tx_rd_addr_q  <= 16'd0;
      tx_out_cnt_q  <= 16'd0;
      tx_src_b0_q   <= 8'h00; tx_src_b1_q <= 8'h00;
      tx_dst_b0_q   <= 8'h00; tx_dst_b1_q <= 8'h00;
      req_valid_q   <= 1'b0;
      cnt_rx_q      <= 16'd0;
      cnt_tx_q      <= 16'd0;
    end else begin

      // ---- TX FSM ----
      case (tx_state_q)

        TX_IDLE: begin
          if (req_valid_q) begin
            tx_dst_mac_q  <= src_mac_q;
            tx_dst_ip_q   <= src_ip_q;
            tx_src_b0_q   <= src_b0_q;
            tx_src_b1_q   <= src_b1_q;
            tx_dst_b0_q   <= dst_b0_q;
            tx_dst_b1_q   <= dst_b1_q;
            tx_udp_len_q  <= {len_b0_q, len_b1_q};
            tx_data_len_q <= rx_data_cnt_q;
            tx_hdr_cnt_q  <= 3'd0;
            tx_rd_addr_q  <= 16'd0;   // read pointer starts at 0 (pre-fetch mem[0])
            tx_out_cnt_q  <= 16'd0;
            tx_state_q    <= TX_META;
          end
        end

        TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i)
            tx_state_q <= TX_HDR;
        end

        TX_HDR: begin
          if (tx_fire_w) begin
            if (tx_hdr_cnt_q == 3'd7) begin
              if (tx_data_len_q == 16'd0) begin
                req_valid_q <= 1'b0;
                cnt_tx_q    <= cnt_tx_q + 16'd1;
                tx_state_q  <= TX_IDLE;
              end else begin
                // Advance read pointer to 1: always_ff reads mem[0] this edge,
                // tx_data_byte_q will hold mem[0] at TX_DATA cycle 0.
                tx_rd_addr_q <= 16'd1;
                tx_out_cnt_q <= 16'd0;
                tx_state_q   <= TX_DATA;
              end
            end else begin
              tx_hdr_cnt_q <= tx_hdr_cnt_q + 3'd1;
            end
          end
        end

        TX_DATA: begin
          if (tx_fire_w) begin
            if (tx_out_cnt_q == tx_data_len_q - 16'd1) begin
              req_valid_q  <= 1'b0;
              cnt_tx_q     <= cnt_tx_q + 16'd1;
              tx_state_q   <= TX_IDLE;
              tx_rd_addr_q <= 16'd0;
              tx_out_cnt_q <= 16'd0;
            end else begin
              tx_out_cnt_q <= tx_out_cnt_q + 16'd1;
              tx_rd_addr_q <= tx_rd_addr_q + 16'd1;
            end
          end
        end

        default: tx_state_q <= TX_IDLE;

      endcase

      // ---- RX FSM ----
      case (rx_state_q)

        RX_IDLE: begin
          if (s_ip_hdr_valid_i && (s_ip_proto_i == 8'h11) &&
              s_ip_accept_i && !req_valid_q && s_axis_tvalid) begin
            src_mac_q     <= s_eth_src_mac_i;
            src_ip_q      <= s_ip_src_ip_i;
            src_b0_q      <= s_axis_tdata;
            drop_q        <= 1'b0;
            port_ok_q     <= 1'b1;
            rx_byte_cnt_q <= 3'd1;
            rx_data_cnt_q <= 16'd0;
            if (s_axis_tlast) begin
              rx_state_q <= RX_IDLE;
            end else begin
              rx_state_q <= RX_HDR;
            end
          end
        end

        RX_HDR: begin
          if (s_axis_tvalid) begin
            case (rx_byte_cnt_q)
              3'd1: src_b1_q    <= s_axis_tdata;
              3'd2: begin
                dst_b0_q   <= s_axis_tdata;
                port_ok_q  <= (s_axis_tdata == local_port_i[15:8]);
              end
              3'd3: begin
                dst_b1_q  <= s_axis_tdata;
                port_ok_q <= port_ok_q && (s_axis_tdata == local_port_i[7:0]);
              end
              3'd4: len_b0_q <= s_axis_tdata;
              3'd5: begin
                len_b1_q <= s_axis_tdata;
                if (len_b0_q == 8'h00 && s_axis_tdata < 8'h08)
                  drop_q <= 1'b1;
              end
              default: ;
            endcase

            if (s_axis_tuser) drop_q <= 1'b1;

            if (rx_byte_cnt_q == 3'd7) begin
              if (!promiscuous_i && !port_ok_q) drop_q <= 1'b1;

              if (s_axis_tlast) begin
                if (!drop_q && (promiscuous_i || port_ok_q) && !s_axis_tuser) begin
                  req_valid_q   <= 1'b1;
                  rx_data_cnt_q <= 16'd0;
                  cnt_rx_q      <= cnt_rx_q + 16'd1;
                end
                rx_state_q <= RX_IDLE;
              end else begin
                rx_byte_cnt_q <= 3'd0;
                rx_data_cnt_q <= 16'd0;
                if (drop_q || (!promiscuous_i && !port_ok_q))
                  rx_state_q <= RX_DRAIN;
                else
                  rx_state_q <= RX_DATA;
              end
            end else if (s_axis_tlast) begin
              rx_state_q    <= RX_IDLE;
              rx_byte_cnt_q <= 3'd0;
            end else begin
              rx_byte_cnt_q <= rx_byte_cnt_q + 3'd1;
            end
          end
        end

        RX_DATA: begin
          if (s_axis_tvalid) begin
            if (s_axis_tuser) drop_q <= 1'b1;
            if (rx_data_cnt_q < 16'(MAX_DATA_BYTES))
              rx_data_cnt_q <= rx_data_cnt_q + 16'd1;
            if (s_axis_tlast) begin
              if (!drop_q && !s_axis_tuser) begin
                req_valid_q <= 1'b1;
                cnt_rx_q    <= cnt_rx_q + 16'd1;
              end
              rx_state_q <= RX_IDLE;
            end
          end
        end

        RX_DRAIN: begin
          if (s_axis_tvalid && s_axis_tlast) begin
            rx_state_q <= RX_IDLE;
          end
        end

        default: rx_state_q <= RX_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign m_meta_valid_o       = (tx_state_q == TX_META);
  assign m_meta_proto_o       = 8'h11;   // UDP
  assign m_meta_dst_ip_o      = tx_dst_ip_q;
  assign m_meta_dst_mac_o     = tx_dst_mac_q;
  assign m_meta_payload_len_o = tx_udp_len_q;

  assign m_axis_tdata_o  = (tx_state_q == TX_HDR) ? tx_hdr_byte_w : tx_data_byte_q;
  assign m_axis_tvalid_o = (tx_state_q == TX_HDR) || (tx_state_q == TX_DATA);
  assign m_axis_tlast_o  = ((tx_state_q == TX_HDR) && (tx_hdr_cnt_q == 3'd7) &&
                             (tx_data_len_q == 16'd0)) ||
                           ((tx_state_q == TX_DATA) &&
                            (tx_out_cnt_q == tx_data_len_q - 16'd1));
  assign m_axis_tuser_o  = 1'b0;

  assign stat_rx_frames = cnt_rx_q;
  assign stat_tx_frames = cnt_tx_q;

endmodule

`endif // UDP_ECHO_SV
