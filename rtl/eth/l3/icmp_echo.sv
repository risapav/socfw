/**
 * @file icmp_echo.sv
 * @brief ICMP echo reply: buffers incoming ICMP echo request, generates reply.
 * @param LOCAL_IP       32-bit FPGA IP (passed to ipv4_tx).
 * @param MAX_DATA_BYTES Max ICMP data bytes buffered (bytes 4+: id, seq, data).
 * @details Receives IPv4 payload stream from ipv4_rx.  Activates when ipv4_rx
 *   fires m_hdr_valid_o with proto=0x01 (ICMP) and accept=1.
 *   Byte 0 of ICMP stream arrives in the SAME cycle as s_ip_hdr_valid_i.
 *
 *   Accepts only type=8 (echo request), code=0.
 *   Checksum adjustment: reply_csum = fold(request_csum + 0x0800) - ones-complement.
 *   Buffers bytes 4+ (id, seq, payload) in icmp_data_mem[].
 *
 *   One frame at a time: RX ignores new frames while req_valid_q=1 (TX pending/busy).
 *
 *   Output stream to ipv4_tx: 4-byte ICMP reply header (type=0, code=0, csum) + data.
 *   Meta to ipv4_tx: proto=0x01, dst_ip=src_ip_q, dst_mac=s_eth_src_mac_i (latched).
 *
 *   s_eth_src_mac_i must be stable for the entire frame duration (e.g. from
 *   eth_type_demux m1_hdr_src_mac or from a top-level registered capture).
 *
 *   No s_axis_tready: module accepts all bytes at full rate (no backpressure upstream).
 *
 *   TX data RAM read is pipelined: tx_rd_addr_q runs 1 cycle ahead of tx_out_cnt_q,
 *   and the icmp_data_mem read is registered (M9K outdata_reg). This breaks the
 *   portb_address_reg0 -> m_axis_tdata_o timing bottleneck.
 */
`ifndef ICMP_ECHO_SV
`define ICMP_ECHO_SV

`default_nettype none

module icmp_echo #(
  parameter logic [31:0] LOCAL_IP       = 32'hC0A80002,
  parameter int          MAX_DATA_BYTES = 1500
) (
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  // ---- From eth_type_demux/top-level: source MAC (stable for entire frame) ----
  input  wire logic [47:0] s_eth_src_mac_i,

  // ---- From ipv4_rx: early header notification (registered 1-cycle pulse) ----
  input  wire logic        s_ip_hdr_valid_i,
  input  wire logic [7:0]  s_ip_proto_i,
  input  wire logic [31:0] s_ip_src_ip_i,
  input  wire logic        s_ip_accept_i,

  // ---- IPv4 payload stream from ipv4_rx (no backpressure) ----
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
  output      logic [15:0] m_meta_payload_len_o,  // ICMP payload len = 4 + data_len

  // ---- Payload stream to ipv4_tx (with backpressure) ----
  output      logic [7:0]  m_axis_tdata_o,
  output      logic        m_axis_tvalid_o,
  input  wire logic        m_axis_tready_i,
  output      logic        m_axis_tlast_o,
  output      logic        m_axis_tuser_o,

  // ---- Diagnostics ----
  output      logic [15:0] stat_rx_requests,
  output      logic [15:0] stat_tx_replies
);

  // -------------------------------------------------------------------------
  // RX FSM states
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    RX_IDLE = 2'd0,
    RX_HDR  = 2'd1,  // capture ICMP header bytes 0-3
    RX_DATA = 2'd2   // buffer bytes 4+
  } rx_state_e;

  // TX FSM states
  typedef enum logic [2:0] {
    TX_IDLE = 3'd0,
    TX_META = 3'd1,
    TX_HDR  = 3'd2,  // send 4-byte ICMP reply header
    TX_DATA = 3'd3
  } tx_state_e;

  rx_state_e rx_state_q;
  tx_state_e tx_state_q;

  // RX registers
  logic [1:0]  rx_byte_cnt_q;   // 0..3 for ICMP header
  logic [7:0]  icmp_type_q;
  logic [15:0] icmp_csum_q;     // request checksum (bytes 2-3)
  logic        drop_q;
  logic [47:0] src_mac_q;
  logic [31:0] src_ip_q;
  logic [15:0] rx_data_cnt_q;   // bytes written to icmp_data_mem

  // TX registers
  logic [47:0] tx_dst_mac_q;
  logic [31:0] tx_dst_ip_q;
  logic [15:0] tx_csum_q;       // request csum, adjusted at reply time
  logic [15:0] tx_data_len_q;   // number of data bytes (bytes 4+)
  logic [1:0]  tx_hdr_cnt_q;    // 0..3 for TX ICMP reply header
  // tx_rd_addr_q: read pointer into icmp_data_mem, runs 1 cycle ahead of output
  logic [15:0] tx_rd_addr_q;
  // tx_out_cnt_q: tracks which output byte is currently on the wire (for tlast)
  logic [15:0] tx_out_cnt_q;

  // Handoff signal: RX -> TX
  logic req_valid_q;

  // Statistics
  logic [15:0] cnt_rx_q;
  logic [15:0] cnt_tx_q;

  // ICMP data buffer: registered read breaks portb_address_reg0 timing path
  (* ramstyle = "M9K" *) logic [7:0] icmp_data_mem [0:MAX_DATA_BYTES-1];

  // -------------------------------------------------------------------------
  // Ones-complement checksum adjustment for reply (combinatorial from tx_csum_q)
  // reply_csum = fold(request_csum + 0x0800)
  // -------------------------------------------------------------------------
  logic [16:0] csum_adj_w;
  logic [15:0] icmp_reply_csum_w;
  assign csum_adj_w        = {1'b0, tx_csum_q} + 17'h0800;
  assign icmp_reply_csum_w = csum_adj_w[15:0] + {15'd0, csum_adj_w[16]};

  // TX header ROM (4 bytes)
  logic [7:0] tx_hdr_byte_w;
  always_comb begin
    case (tx_hdr_cnt_q)
      2'd0:    tx_hdr_byte_w = 8'h00;                    // type = echo reply
      2'd1:    tx_hdr_byte_w = 8'h00;                    // code = 0
      2'd2:    tx_hdr_byte_w = icmp_reply_csum_w[15:8];
      2'd3:    tx_hdr_byte_w = icmp_reply_csum_w[7:0];
      default: tx_hdr_byte_w = 8'h00;
    endcase
  end

  // -------------------------------------------------------------------------
  // Data memory write (no reset — M9K block RAM inference)
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rx_state_q == RX_DATA && s_axis_tvalid &&
        (rx_data_cnt_q < 16'(MAX_DATA_BYTES))) begin
      icmp_data_mem[rx_data_cnt_q[$clog2(MAX_DATA_BYTES)-1:0]] <= s_axis_tdata;
    end
  end

  // Registered read: tx_rd_addr_q runs 1 cycle ahead so data is ready on time.
  // Quartus infers M9K with outdata_reg, eliminating portb_address_reg0 timing path.
  logic [7:0] tx_data_byte_q;
  always_ff @(posedge clk_i) begin
    tx_data_byte_q <= icmp_data_mem[tx_rd_addr_q[$clog2(MAX_DATA_BYTES)-1:0]];
  end

  // -------------------------------------------------------------------------
  // TX fire signal
  // -------------------------------------------------------------------------
  logic tx_fire_w;
  assign tx_fire_w = m_axis_tvalid_o && m_axis_tready_i;

  // -------------------------------------------------------------------------
  // Combined RX + TX FSM
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_state_q    <= RX_IDLE;
      tx_state_q    <= TX_IDLE;
      rx_byte_cnt_q <= 2'd0;
      icmp_type_q   <= 8'h00;
      icmp_csum_q   <= 16'h0000;
      drop_q        <= 1'b0;
      src_mac_q     <= '0;
      src_ip_q      <= '0;
      rx_data_cnt_q <= 16'd0;
      tx_dst_mac_q  <= '0;
      tx_dst_ip_q   <= '0;
      tx_csum_q     <= 16'h0000;
      tx_data_len_q <= 16'd0;
      tx_hdr_cnt_q  <= 2'd0;
      tx_rd_addr_q  <= 16'd0;
      tx_out_cnt_q  <= 16'd0;
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
            tx_csum_q     <= icmp_csum_q;
            tx_data_len_q <= rx_data_cnt_q;
            tx_hdr_cnt_q  <= 2'd0;
            tx_rd_addr_q  <= 16'd0;   // read pointer starts at 0 (pre-fetch mem[0])
            tx_out_cnt_q  <= 16'd0;
            tx_state_q    <= TX_META;
          end
        end

        TX_META: begin
          if (m_meta_valid_o && m_meta_ready_i) begin
            tx_state_q <= TX_HDR;
          end
        end

        TX_HDR: begin
          if (tx_fire_w) begin
            if (tx_hdr_cnt_q == 2'd3) begin
              if (tx_data_len_q == 16'd0) begin
                req_valid_q <= 1'b0;
                cnt_tx_q    <= cnt_tx_q + 16'd1;
                tx_state_q  <= TX_IDLE;
              end else begin
                // Advance read pointer to 1: next always_ff reads mem[0],
                // tx_data_byte_q will hold mem[0] at TX_DATA cycle 0.
                tx_rd_addr_q <= 16'd1;
                tx_out_cnt_q <= 16'd0;
                tx_state_q   <= TX_DATA;
              end
            end else begin
              tx_hdr_cnt_q <= tx_hdr_cnt_q + 2'd1;
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
          // Activate only if proto=ICMP, accepted, and TX not busy
          if (s_ip_hdr_valid_i && (s_ip_proto_i == 8'h01) &&
              s_ip_accept_i && !req_valid_q && s_axis_tvalid) begin
            src_mac_q     <= s_eth_src_mac_i;
            src_ip_q      <= s_ip_src_ip_i;
            icmp_type_q   <= s_axis_tdata;
            drop_q        <= (s_axis_tdata != 8'h08);  // must be echo request
            rx_byte_cnt_q <= 2'd1;
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
              2'd1: drop_q              <= drop_q || (s_axis_tdata != 8'h00);
              2'd2: icmp_csum_q[15:8]  <= s_axis_tdata;
              2'd3: icmp_csum_q[7:0]   <= s_axis_tdata;
              default: ;
            endcase

            if (rx_byte_cnt_q == 2'd3) begin
              if (s_axis_tlast) begin
                if (!drop_q && !s_axis_tuser) begin
                  req_valid_q   <= 1'b1;
                  rx_data_cnt_q <= 16'd0;
                  cnt_rx_q      <= cnt_rx_q + 16'd1;
                end
                rx_state_q <= RX_IDLE;
              end else begin
                rx_byte_cnt_q <= 2'd0;
                rx_data_cnt_q <= 16'd0;
                rx_state_q    <= RX_DATA;
              end
            end else if (s_axis_tlast) begin
              rx_state_q    <= RX_IDLE;
              rx_byte_cnt_q <= 2'd0;
            end else begin
              rx_byte_cnt_q <= rx_byte_cnt_q + 2'd1;
            end
          end
        end

        RX_DATA: begin
          if (s_axis_tvalid) begin
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

        default: rx_state_q <= RX_IDLE;

      endcase
    end
  end

  // -------------------------------------------------------------------------
  // Output wiring
  // -------------------------------------------------------------------------
  assign m_meta_valid_o       = (tx_state_q == TX_META);
  assign m_meta_proto_o       = 8'h01;   // ICMP
  assign m_meta_dst_ip_o      = tx_dst_ip_q;
  assign m_meta_dst_mac_o     = tx_dst_mac_q;
  assign m_meta_payload_len_o = tx_data_len_q + 16'd4;  // 4B header + data

  assign m_axis_tdata_o  = (tx_state_q == TX_HDR) ? tx_hdr_byte_w : tx_data_byte_q;
  assign m_axis_tvalid_o = (tx_state_q == TX_HDR) || (tx_state_q == TX_DATA);
  assign m_axis_tlast_o  = ((tx_state_q == TX_HDR) && (tx_hdr_cnt_q == 2'd3) &&
                             (tx_data_len_q == 16'd0)) ||
                           ((tx_state_q == TX_DATA) &&
                            (tx_out_cnt_q == tx_data_len_q - 16'd1));
  assign m_axis_tuser_o  = 1'b0;

  assign stat_rx_requests = cnt_rx_q;
  assign stat_tx_replies  = cnt_tx_q;

endmodule

`endif // ICMP_ECHO_SV
