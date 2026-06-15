/**
 * @file        xfcp_udp_tx_adapter.sv
 * @brief       Adaptér pre konverziu XFCP odpovedí do UDP datagramov.
 * @details     Vyčkáva na XFCP byte stream. Pred odoslaním prvého bajtu iniciuje
 * prenos UDP metadát (IP a port pôvodného odosielateľa) a následne odosiela payload.
 * @param       XFCP_PORT Zdrojový UDP port pre odosielané pakety (default: 50000).
 */

`ifndef XFCP_UDP_TX_ADAPTER_SV
`define XFCP_UDP_TX_ADAPTER_SV

`default_nettype none

module xfcp_udp_tx_adapter #(
  parameter logic [15:0] XFCP_PORT = 16'd50000
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  // Saved metadata from RX adapter
  input  logic [31:0] saved_dst_ip_i,
  input  logic [15:0] saved_dst_port_i,

  // XFCP output stream from fabric endpoint
  input  logic        xfcp_tx_valid_i,
  output logic        xfcp_tx_ready_o,
  input  logic [7:0]  xfcp_tx_data_i,
  input  logic        xfcp_tx_last_i,

  // UDP TX metadata handshake
  output logic        udp_tx_meta_valid_o,
  input  logic        udp_tx_meta_ready_i,
  output logic [31:0] udp_tx_dst_ip_o,
  output logic [15:0] udp_tx_dst_port_o,
  output logic [15:0] udp_tx_src_port_o,

  // UDP TX payload stream
  output logic        udp_tx_valid_o,
  input  logic        udp_tx_ready_i,
  output logic [7:0]  udp_tx_data_o,
  output logic        udp_tx_last_o
);

  typedef enum logic [1:0] {
    ST_TX_IDLE = 2'd0,
    ST_TX_META = 2'd1,
    ST_TX_SEND = 2'd2
  } tx_state_e;

  tx_state_e state_q;
  tx_state_e state_d;

  assign udp_tx_dst_ip_o   = saved_dst_ip_i;
  assign udp_tx_dst_port_o = saved_dst_port_i;
  assign udp_tx_src_port_o = XFCP_PORT;

  assign udp_tx_data_o = xfcp_tx_data_i;
  assign udp_tx_last_o = xfcp_tx_last_i;

  always_comb begin
    state_d             = state_q;
    xfcp_tx_ready_o     = 1'b0;
    udp_tx_meta_valid_o = 1'b0;
    udp_tx_valid_o      = 1'b0;

    case (state_q)
      ST_TX_IDLE: begin
        if (xfcp_tx_valid_i) begin
          state_d = ST_TX_META;
        end
      end

      ST_TX_META: begin
        udp_tx_meta_valid_o = 1'b1;
        if (udp_tx_meta_ready_i) begin
          // Meta potvrdene, mozeme uvolnit aj prvy bajt dat
          udp_tx_valid_o  = xfcp_tx_valid_i;
          xfcp_tx_ready_o = udp_tx_ready_i;

          if (xfcp_tx_valid_i && udp_tx_ready_i) begin
            state_d = xfcp_tx_last_i ? ST_TX_IDLE : ST_TX_SEND;
          end else begin
            state_d = ST_TX_SEND;
          end
        end
      end

      ST_TX_SEND: begin
        udp_tx_valid_o  = xfcp_tx_valid_i;
        xfcp_tx_ready_o = udp_tx_ready_i;

        if (xfcp_tx_valid_i && udp_tx_ready_i && xfcp_tx_last_i) begin
          state_d = ST_TX_IDLE;
        end
      end

      default: begin
        state_d = ST_TX_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= ST_TX_IDLE;
    end else begin
      state_q <= state_d;
    end
  end

endmodule

`default_nettype wire

`endif // XFCP_UDP_TX_ADAPTER_SV
