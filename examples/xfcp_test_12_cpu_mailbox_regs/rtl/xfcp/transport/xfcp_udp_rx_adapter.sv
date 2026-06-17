/**
 * @file        xfcp_udp_rx_adapter.sv
 * @brief       Adaptér pre príjem UDP datagramov a ich konverziu na XFCP byte stream.
 * @details     Filtruje prichádzajúce UDP pakety podľa cieľového portu. Platné pakety
 * prepúšťa do XFCP, neplatné zahadzuje. Ukladá zdrojovú IP a port pre TX odpoveď.
 * @param       XFCP_PORT UDP port určený pre komunikáciu s XFCP (default: 50000).
 */

`ifndef XFCP_UDP_RX_ADAPTER_SV
`define XFCP_UDP_RX_ADAPTER_SV

`default_nettype none

module xfcp_udp_rx_adapter #(
  parameter logic [15:0] XFCP_PORT = 16'd50000
)(
  input  logic        clk_i,
  input  logic        rst_ni,

  // UDP RX payload stream
  input  logic        udp_rx_valid_i,
  output logic        udp_rx_ready_o,
  input  logic [7:0]  udp_rx_data_i,
  input  logic        udp_rx_last_i,

  // UDP RX metadata
  input  logic [31:0] udp_rx_src_ip_i,
  input  logic [15:0] udp_rx_src_port_i,
  input  logic [15:0] udp_rx_dst_port_i,

  // XFCP stream into fabric endpoint
  output logic        xfcp_rx_valid_o,
  input  logic        xfcp_rx_ready_i,
  output logic [7:0]  xfcp_rx_data_o,
  output logic        xfcp_rx_last_o,

  // Saved metadata for TX adapter
  output logic [31:0] saved_src_ip_o,
  output logic [15:0] saved_src_port_o
);

  typedef enum logic [1:0] {
    ST_RX_IDLE    = 2'd0,
    ST_RX_FORWARD = 2'd1,
    ST_RX_DROP    = 2'd2
  } rx_state_e;

  rx_state_e state_q;
  rx_state_e state_d;

  logic [31:0] saved_ip_q;
  logic [15:0] saved_port_q;

  assign saved_src_ip_o   = saved_ip_q;
  assign saved_src_port_o = saved_port_q;

  assign xfcp_rx_data_o = udp_rx_data_i;
  assign xfcp_rx_last_o = udp_rx_last_i;

  always_comb begin
    state_d         = state_q;
    udp_rx_ready_o  = 1'b0;
    xfcp_rx_valid_o = 1'b0;

    case (state_q)
      ST_RX_IDLE: begin
        if (udp_rx_valid_i) begin
          if (udp_rx_dst_port_i == XFCP_PORT) begin
            // Validny port, prechod do preposielania
            xfcp_rx_valid_o = 1'b1;
            udp_rx_ready_o  = xfcp_rx_ready_i;
            if (xfcp_rx_ready_i) begin
              state_d = udp_rx_last_i ? ST_RX_IDLE : ST_RX_FORWARD;
            end
          end else begin
            // Zly port, zahadzujeme datagram
            udp_rx_ready_o = 1'b1;
            state_d        = udp_rx_last_i ? ST_RX_IDLE : ST_RX_DROP;
          end
        end
      end

      ST_RX_FORWARD: begin
        xfcp_rx_valid_o = udp_rx_valid_i;
        udp_rx_ready_o  = xfcp_rx_ready_i;
        if (udp_rx_valid_i && xfcp_rx_ready_i && udp_rx_last_i) begin
          state_d = ST_RX_IDLE;
        end
      end

      ST_RX_DROP: begin
        udp_rx_ready_o = 1'b1;
        if (udp_rx_valid_i && udp_rx_last_i) begin
          state_d = ST_RX_IDLE;
        end
      end

      default: begin
        state_d = ST_RX_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= ST_RX_IDLE;
      saved_ip_q   <= '0;
      saved_port_q <= '0;
    end else begin
      state_q <= state_d;

      // Latchnutie IP a portu pri prvom bajte noveho paketu
      if (state_q == ST_RX_IDLE && udp_rx_valid_i && (udp_rx_dst_port_i == XFCP_PORT)) begin
        saved_ip_q   <= udp_rx_src_ip_i;
        saved_port_q <= udp_rx_src_port_i;
      end
    end
  end

endmodule

`default_nettype wire

`endif // XFCP_UDP_RX_ADAPTER_SV
