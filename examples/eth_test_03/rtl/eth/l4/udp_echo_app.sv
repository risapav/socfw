/**
 * @file udp_echo_app.sv
 * @brief UDP Echo application: stores RX payload in buffer and echoes it back.
 * @details FSM:
 *   ST_IDLE      — waits for rx_meta_valid_i, latches metadata into rx_meta_q.
 *   ST_RX        — stores incoming payload bytes; transitions on s_axis_tlast.
 *   ST_TX_META   — presents tx_meta_o, waits for tx_meta_ready_i.
 *   ST_TX_PAYLOAD — streams buffered payload back; generates m_axis_tlast.
 *
 * rx_meta_i is sampled only once (in ST_IDLE) and must not be used after that.
 * rx_meta_ready_o is 1 only in ST_IDLE so a second packet cannot pre-empt RX.
 *
 * @param MAX_PAYLOAD_BYTES  Buffer depth; default 1500. Excess bytes are dropped.
 */

`ifndef UDP_ECHO_APP_SV
`define UDP_ECHO_APP_SV

`default_nettype none

import eth_pkg::*;

module udp_echo_app #(
  parameter int MAX_PAYLOAD_BYTES = 1500
)(
  input  wire logic        clk_i,
  input  wire logic        rst_ni,

  input  wire logic        rx_meta_valid_i,
  output      logic        rx_meta_ready_o,
  input       udp_packet_meta_t rx_meta_i,

  input  wire logic [7:0]  s_axis_tdata,
  input  wire logic        s_axis_tvalid,
  output      logic        s_axis_tready,
  input  wire logic        s_axis_tlast,

  output      logic        tx_meta_valid_o,
  input  wire logic        tx_meta_ready_i,
  output      udp_packet_meta_t tx_meta_o,

  output      logic [7:0]  m_axis_tdata,
  output      logic        m_axis_tvalid,
  input  wire logic        m_axis_tready,
  output      logic        m_axis_tlast
);

  typedef enum logic [1:0] {
    ST_IDLE       = 2'd0,
    ST_RX         = 2'd1,
    ST_TX_META    = 2'd2,
    ST_TX_PAYLOAD = 2'd3
  } state_e;

  localparam int PTR_W = $clog2(MAX_PAYLOAD_BYTES + 1);

  state_e                        state_q;
  logic [PTR_W-1:0]              write_ptr_q;
  logic [PTR_W-1:0]              read_ptr_q;
  logic [7:0]                    mem [0:MAX_PAYLOAD_BYTES-1];
  udp_packet_meta_t     rx_meta_q;

  wire last_read_w = (read_ptr_q == PTR_W'(rx_meta_q.payload_len) - {{(PTR_W-1){1'b0}}, 1'b1});

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= ST_IDLE;
      write_ptr_q <= '0;
      read_ptr_q  <= '0;
      rx_meta_q   <= '0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (rx_meta_valid_i && rx_meta_ready_o) begin
            rx_meta_q  <= rx_meta_i;
            read_ptr_q <= '0;
            if (rx_meta_i.payload_len == '0) begin
              // Zero-payload: skip RX buffer, go straight to TX.
              write_ptr_q <= '0;
              state_q     <= ST_TX_META;
            end else begin
              state_q <= ST_RX;
              // Capture first payload byte that arrives simultaneously with meta handshake.
              // s_axis_tready is 1 in ST_IDLE when rx_meta_valid_i=1 (see assign below).
              if (s_axis_tvalid) begin
                mem[0]      <= s_axis_tdata;
                write_ptr_q <= PTR_W'(1);
                // 1-byte payload: first byte has tlast; skip ST_RX entirely.
                if (s_axis_tlast) state_q <= ST_TX_META;
              end else begin
                write_ptr_q <= '0;
              end
            end
          end
        end
        ST_RX: begin
          if (s_axis_tvalid && s_axis_tready) begin
            if (write_ptr_q < PTR_W'(MAX_PAYLOAD_BYTES)) begin
              mem[write_ptr_q] <= s_axis_tdata;
              write_ptr_q      <= write_ptr_q + 1'b1;
            end
            if (s_axis_tlast) state_q <= ST_TX_META;
          end
        end
        ST_TX_META: begin
          if (tx_meta_ready_i)
            state_q <= (rx_meta_q.payload_len == '0) ? ST_IDLE : ST_TX_PAYLOAD;
        end
        ST_TX_PAYLOAD: begin
          if (m_axis_tready) begin
            if (last_read_w) begin
              state_q    <= ST_IDLE;
              read_ptr_q <= '0;
            end else begin
              read_ptr_q <= read_ptr_q + 1'b1;
            end
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign rx_meta_ready_o = (state_q == ST_IDLE);
  // Assert tready in ST_RX (normal) or in ST_IDLE when meta is valid so the
  // first payload byte arrives simultaneously with the meta handshake.
  assign s_axis_tready   = (state_q == ST_RX) || (state_q == ST_IDLE && rx_meta_valid_i);

  assign m_axis_tdata    = mem[read_ptr_q];
  assign m_axis_tvalid   = (state_q == ST_TX_PAYLOAD);
  assign m_axis_tlast    = m_axis_tvalid && last_read_w;

  assign tx_meta_valid_o = (state_q == ST_TX_META);
  assign tx_meta_o = '{
    src_mac:     rx_meta_q.dst_mac,
    dst_mac:     rx_meta_q.src_mac,
    src_ip:      rx_meta_q.dst_ip,
    dst_ip:      rx_meta_q.src_ip,
    src_port:    rx_meta_q.dst_port,
    dst_port:    rx_meta_q.src_port,
    payload_len: rx_meta_q.payload_len
  };

endmodule

`endif // UDP_ECHO_APP_SV
