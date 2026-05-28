/**
 * @file        ipreceive.sv
 * @brief       GMII UDP prijimaci modul.
 * @details     Prijima data z GMII, extrahuje MAC, IP, UDP hlavicky a data.
 *              Parametrom EXPECT_PREAMBLE sa riadi, ci parser ocakava preambulu
 *              a SFD pred destination MAC. Pri EXPECT_PREAMBLE=0 je prvy bajt
 *              po rx_dv_i=1 priamo prvym bajtom destination MAC.
 *              rx_er_i=1 pocas prijmu okamzite zahodi rozpracovany ramec.
 *
 * @param EXPECT_PREAMBLE 1=ocakavaj 7x 0x55 + 0xD5 pred MAC (default)
 *                        0=prvy bajt rx_dv_i je uz destination MAC[0]
 */
`ifndef IP_RECEIVE_SV
`define IP_RECEIVE_SV

`default_nettype none

module ipreceive #(
  parameter bit EXPECT_PREAMBLE = 1'b1
)(
  input  wire          clk_i,
  input  wire          rst_ni,
  input  wire  [7:0]   rx_data_i,
  input  wire          rx_dv_i,
  input  wire          rx_er_i,

  output logic [47:0]  board_mac_o,
  output logic [47:0]  pc_mac_o,
  output logic [15:0]  ip_protocol_o,
  output logic         valid_ip_p_o,
  output logic [159:0] ip_layer_o,
  output logic [31:0]  pc_ip_o,
  output logic [31:0]  board_ip_o,
  output logic [63:0]  udp_layer_o,

  output logic [31:0]  data_o,
  output logic [15:0]  rx_total_length_o,
  output logic         data_o_valid_o,
  output logic [3:0]   rx_state_o,
  output logic [15:0]  rx_data_length_o,
  output logic [8:0]   ram_wr_addr_o,
  output logic         data_receive_o
);

  typedef enum logic [3:0] {
    ST_IDLE           = 4'd0,
    ST_SIX_55         = 4'd1,
    ST_SPD_D5         = 4'd2,
    ST_RX_MAC         = 4'd3,
    ST_RX_IP_PROTOCOL = 4'd4,
    ST_RX_IP_LAYER    = 4'd5,
    ST_RX_UDP_LAYER   = 4'd6,
    ST_RX_DATA        = 4'd7,
    ST_RX_FINISH      = 4'd8
  } rx_state_e;

  rx_state_e  state_q;
  logic [15:0]  my_ip_protocol_q;
  logic [159:0] my_ip_layer_q;
  logic [63:0]  my_udp_layer_q;
  logic [31:0]  my_data_q;
  logic [2:0]   byte_counter_q;
  logic [4:0]   state_counter_q;
  logic [95:0]  my_mac_q;
  logic [15:0]  data_counter_q;

  assign rx_state_o = state_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= ST_IDLE;
      data_receive_o    <= 1'b0;
      valid_ip_p_o      <= 1'b0;
      byte_counter_q    <= 3'd0;
      data_counter_q    <= 16'd0;
      my_data_q         <= 32'd0;
      state_counter_q   <= 5'd0;
      data_o_valid_o    <= 1'b0;
      ram_wr_addr_o     <= 9'd0;
      board_mac_o       <= 48'd0;
      pc_mac_o          <= 48'd0;
      ip_protocol_o     <= 16'd0;
      ip_layer_o        <= 160'd0;
      pc_ip_o           <= 32'd0;
      board_ip_o        <= 32'd0;
      udp_layer_o       <= 64'd0;
      data_o            <= 32'd0;
      rx_total_length_o <= 16'd0;
      rx_data_length_o  <= 16'd0;
      my_ip_protocol_q  <= 16'd0;
      my_ip_layer_q     <= 160'd0;
      my_udp_layer_q    <= 64'd0;
      my_mac_q          <= 96'd0;
    end else begin
      data_receive_o <= 1'b0;
      // rx_er_i pocas prijmu zahodi rozpracovany ramec
      if (rx_er_i && (state_q != ST_IDLE)) begin
        state_q <= ST_IDLE;
      end else begin
        case (state_q)
          ST_IDLE: begin
            valid_ip_p_o    <= 1'b0;
            byte_counter_q  <= 3'd0;
            data_counter_q  <= 16'd0;
            my_data_q       <= 32'd0;
            state_counter_q <= 5'd0;
            data_o_valid_o  <= 1'b0;
            ram_wr_addr_o   <= 9'd0;
            if (rx_dv_i) begin
              if (EXPECT_PREAMBLE) begin
                if (rx_data_i == 8'h55) begin
                  state_q   <= ST_SIX_55;
                  my_data_q <= {my_data_q[23:0], rx_data_i};
                end
              end else begin
                // Prvy bajt je uz destination MAC[0]
                my_mac_q        <= {88'd0, rx_data_i};
                state_counter_q <= 5'd1;  // prekonzumovany 1 bajt
                state_q         <= ST_RX_MAC;
              end
            end
          end

          ST_SIX_55: begin
            if ((rx_data_i == 8'h55) && rx_dv_i) begin
              if (state_counter_q == 5'd5) begin
                state_counter_q <= 5'd0;
                state_q         <= ST_SPD_D5;
              end else begin
                state_counter_q <= state_counter_q + 1'b1;
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_SPD_D5: begin
            if ((rx_data_i == 8'hD5) && rx_dv_i) begin
              state_q <= ST_RX_MAC;
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_MAC: begin
            if (rx_dv_i) begin
              if (state_counter_q < 5'd11) begin
                my_mac_q        <= {my_mac_q[87:0], rx_data_i};
                state_counter_q <= state_counter_q + 1'b1;
              end else begin
                board_mac_o     <= my_mac_q[87:40];
                pc_mac_o        <= {my_mac_q[39:0], rx_data_i};
                state_counter_q <= 5'd0;
                if ((my_mac_q[87:72] == 16'h000A) &&
                    (my_mac_q[71:56] == 16'h3501) &&
                    (my_mac_q[55:40] == 16'hFEC0)) begin
                  state_q <= ST_RX_IP_PROTOCOL;
                end else begin
                  state_q <= ST_IDLE;
                end
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_IP_PROTOCOL: begin
            if (rx_dv_i) begin
              if (state_counter_q < 5'd1) begin
                my_ip_protocol_q <= {my_ip_protocol_q[7:0], rx_data_i};
                state_counter_q  <= state_counter_q + 1'b1;
              end else begin
                ip_protocol_o   <= {my_ip_protocol_q[7:0], rx_data_i};
                valid_ip_p_o    <= 1'b1;
                state_counter_q <= 5'd0;
                state_q         <= ST_RX_IP_LAYER;
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_IP_LAYER: begin
            valid_ip_p_o <= 1'b0;
            if (rx_dv_i) begin
              if (state_counter_q < 5'd19) begin
                my_ip_layer_q   <= {my_ip_layer_q[151:0], rx_data_i};
                state_counter_q <= state_counter_q + 1'b1;
              end else begin
                ip_layer_o      <= {my_ip_layer_q[151:0], rx_data_i};
                state_counter_q <= 5'd0;
                state_q         <= ST_RX_UDP_LAYER;
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_UDP_LAYER: begin
            rx_total_length_o <= ip_layer_o[143:128];
            pc_ip_o           <= ip_layer_o[63:32];
            board_ip_o        <= ip_layer_o[31:0];
            if (rx_dv_i) begin
              if (state_counter_q < 5'd7) begin
                my_udp_layer_q  <= {my_udp_layer_q[55:0], rx_data_i};
                state_counter_q <= state_counter_q + 1'b1;
              end else begin
                udp_layer_o      <= {my_udp_layer_q[55:0], rx_data_i};
                rx_data_length_o <= my_udp_layer_q[23:8];
                state_counter_q  <= 5'd0;
                state_q          <= ST_RX_DATA;
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_DATA: begin
            if (rx_dv_i) begin
              if (data_counter_q == (rx_data_length_o - 16'd9)) begin
                data_counter_q <= 16'd0;
                state_q        <= ST_RX_FINISH;
                ram_wr_addr_o  <= ram_wr_addr_o + 1'b1;
                data_o_valid_o <= 1'b1;
                if (byte_counter_q == 3'd3) begin
                  data_o         <= {my_data_q[23:0], rx_data_i};
                  byte_counter_q <= 3'd0;
                end else if (byte_counter_q == 3'd2) begin
                  data_o         <= {my_data_q[15:0], rx_data_i, 8'h00};
                  byte_counter_q <= 3'd0;
                end else if (byte_counter_q == 3'd1) begin
                  data_o         <= {my_data_q[7:0], rx_data_i, 16'h0000};
                  byte_counter_q <= 3'd0;
                end else begin
                  data_o         <= {rx_data_i, 24'h000000};
                  byte_counter_q <= 3'd0;
                end
              end else begin
                data_counter_q <= data_counter_q + 1'b1;
                if (byte_counter_q < 3'd3) begin
                  my_data_q      <= {my_data_q[23:0], rx_data_i};
                  byte_counter_q <= byte_counter_q + 1'b1;
                  data_o_valid_o <= 1'b0;
                end else begin
                  data_o         <= {my_data_q[23:0], rx_data_i};
                  byte_counter_q <= 3'd0;
                  data_o_valid_o <= 1'b1;
                  ram_wr_addr_o  <= ram_wr_addr_o + 1'b1;
                end
              end
            end else begin
              state_q <= ST_IDLE;
            end
          end

          ST_RX_FINISH: begin
            data_o_valid_o <= 1'b0;
            data_receive_o <= 1'b1;
            state_q        <= ST_IDLE;
          end

          default: begin
            state_q <= ST_IDLE;
          end
        endcase
      end
    end
  end

endmodule

`endif // IP_RECEIVE_SV
