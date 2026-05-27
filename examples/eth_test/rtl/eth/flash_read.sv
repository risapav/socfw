/**
 * @file        flash_read.sv
 * @brief       Modul na citanie dat z externej SPI Flash pamate.
 * @details     Posiela citaci prikaz a adresu, nasledne vycita urceny
 * pocet bajtov (napr. obrazove data). Vyuziva padavu hranu na zapis
 * a nabeznu na citanie podla standardu SPI (Mode 0).
 *
 * @param       FLASH_ADDR Pociatocna adresa vo flash pamati (default: 24'ha0600).
 */

`ifndef FLASH_READ_SV
`define FLASH_READ_SV

`default_nettype none

module flash_read #(
  parameter logic [23:0] FLASH_ADDR = 24'hA0600
)(
  input  wire        clk_i,
  input  wire        rst_ni,
  input  wire        read_req_i,

  // SPI Fyzicke rozhranie
  output logic       spi_cs_no,
  output logic       spi_clk_o,
  output logic       spi_mosi_o,
  input  wire        spi_miso_i,

  // Datove rozhranie (vystup)
  output logic [7:0] data_o,
  output logic       valid_o,
  output logic       read_done_o
);

  localparam logic [7:0] FLASH_READ_CMD = 8'h03; // Prikaz 0x03 pre standardne citanie

  typedef enum logic [2:0] {
    ST_IDLE       = 3'd0,
    ST_CMD_SEND   = 3'd1,
    ST_ADDR_SEND  = 3'd2,
    ST_READ_WAIT  = 3'd3,
    ST_READ_DONE  = 3'd4
  } flash_state_e;

  flash_state_e state_q;

  logic [7:0]   cmd_q;
  logic [23:0]  addr_q;
  logic [4:0]   cnt_tx_q;   // Pocitadlo pre prenos bitov (max 23)
  logic [2:0]   cnt_rx_b_q; // Pocitadlo prijatych bitov v bajte
  logic [18:0]  cnt_rx_w_q; // Pocitadlo prijatych bajtov (pre 391680)

  logic         spi_clk_en_q;
  logic         data_come_q;
  logic         read_finish_q;
  logic [7:0]   my_data_q;
  logic         my_valid_q;

  // Priradenie vystupov
  assign valid_o   = my_valid_q;
  assign data_o    = my_data_q;
  assign spi_clk_o = spi_clk_en_q ? clk_i : 1'b0;

  // ==========================================================================
  // Vysielacia cast (TX) - Padava hrana
  // ==========================================================================
  always_ff @(negedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      spi_cs_no     <= 1'b1;
      spi_mosi_o    <= 1'b1;
      state_q       <= ST_IDLE;
      cmd_q         <= 8'd0;
      addr_q        <= FLASH_ADDR;
      spi_clk_en_q  <= 1'b0;
      cnt_tx_q      <= 5'd0;
      read_done_o   <= 1'b0;
      data_come_q   <= 1'b0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          spi_clk_en_q  <= 1'b0;
          spi_cs_no     <= 1'b1;
          spi_mosi_o    <= 1'b1;
          cmd_q         <= FLASH_READ_CMD;
          addr_q        <= FLASH_ADDR;
          read_done_o   <= 1'b0;
          data_come_q   <= 1'b0;

          if (read_req_i) begin
            state_q  <= ST_CMD_SEND;
            cnt_tx_q <= 5'd7;
          end
        end

        ST_CMD_SEND: begin
          spi_clk_en_q <= 1'b1;
          spi_cs_no    <= 1'b0;
          if (cnt_tx_q > 5'd0) begin
            spi_mosi_o <= cmd_q[cnt_tx_q[2:0]];
            cnt_tx_q   <= cnt_tx_q - 1'b1;
          end else begin
            spi_mosi_o <= cmd_q[0];
            state_q    <= ST_ADDR_SEND;
            cnt_tx_q   <= 5'd23;
          end
        end

        ST_ADDR_SEND: begin
          if (cnt_tx_q > 5'd0) begin
            spi_mosi_o <= addr_q[cnt_tx_q];
            cnt_tx_q   <= cnt_tx_q - 1'b1;
          end else begin
            spi_mosi_o <= addr_q[0];
            state_q    <= ST_READ_WAIT;
            cnt_tx_q   <= 5'd0;
          end
        end

        ST_READ_WAIT: begin
          if (read_finish_q) begin
            state_q     <= ST_READ_DONE;
            data_come_q <= 1'b0;
          end else begin
            data_come_q <= 1'b1;
          end
        end

        ST_READ_DONE: begin
          spi_cs_no    <= 1'b1;
          spi_mosi_o   <= 1'b1;
          read_done_o  <= 1'b1;
          spi_clk_en_q <= 1'b0;
        end

        default: begin
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

  // ==========================================================================
  // Prijimacia cast (RX) - Nabezna hrana
  // ==========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cnt_rx_w_q    <= 19'd0;
      cnt_rx_b_q    <= 3'd0;
      read_finish_q <= 1'b0;
      my_valid_q    <= 1'b0;
      my_data_q     <= 8'd0;
    end else begin
      if (data_come_q) begin
        if (cnt_rx_w_q < 19'd391680) begin
          if (cnt_rx_b_q < 3'd7) begin
            my_valid_q <= 1'b0;
            my_data_q  <= {my_data_q[6:0], spi_miso_i};
            cnt_rx_b_q <= cnt_rx_b_q + 1'b1;
          end else begin
            my_valid_q <= 1'b1;
            my_data_q  <= {my_data_q[6:0], spi_miso_i};
            cnt_rx_b_q <= 3'd0;
            cnt_rx_w_q <= cnt_rx_w_q + 1'b1;
          end
        end else begin
          cnt_rx_w_q    <= 19'd0;
          read_finish_q <= 1'b1;
          my_valid_q    <= 1'b0;
        end
      end else begin
        cnt_rx_w_q    <= 19'd0;
        cnt_rx_b_q    <= 3'd0;
        read_finish_q <= 1'b0;
        my_valid_q    <= 1'b0;
        my_data_q     <= 8'd0;
      end
    end
  end

endmodule


`endif // FLASH_READ_SV
