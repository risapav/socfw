// @file native_word_port.sv
// @brief Native 32-bit SDRAM word port controller.
// @details Splits 32-bit requests into pairs of 16-bit PHY commands.
//          Writes: low halfword (addr+0) then high halfword (addr+1).
//          Reads: 2 sequential read commands, assembled via read_word_assembler.
//          Write-hold states (WR_x_HOLD) keep phy_wdata_oe=1 for 1 extra CLK
//          after each CMD_WR so the SDRAM model captures valid DQ (CMD FF lag,
//          D005 from sdram_test_02).
// @param ADDR_WIDTH       Address bits driven on phy_cmd_addr.
// @param SDRAM_DATA_WIDTH SDRAM halfword width (16).
// @param WORD_DATA_WIDTH  Native word width (32).
`ifndef NATIVE_WORD_PORT_SV
`define NATIVE_WORD_PORT_SV
`default_nettype none

module native_word_port #(
  parameter int ADDR_WIDTH       = 24,
  parameter int SDRAM_DATA_WIDTH = 16,
  parameter int WORD_DATA_WIDTH  = 32
)(
  input  logic                          clk,
  input  logic                          rstn,

  input  logic                          req_valid,
  output logic                          req_ready,
  input  logic                          req_write,
  input  logic [ADDR_WIDTH-1:0]         req_addr,
  input  logic [WORD_DATA_WIDTH-1:0]    req_wdata,

  output logic                          rsp_valid,
  output logic [WORD_DATA_WIDTH-1:0]    rsp_rdata,

  output logic                          phy_cmd_valid,
  input  logic                          phy_cmd_ready,
  output logic                          phy_cmd_write,
  output logic [ADDR_WIDTH-1:0]         phy_cmd_addr,
  output logic [SDRAM_DATA_WIDTH-1:0]   phy_wdata,
  output logic                          phy_wdata_oe,

  input  logic                          phy_rvalid,
  input  logic [SDRAM_DATA_WIDTH-1:0]   phy_rdata
);

  // -------------------------------------------------------------------------
  // State machine
  // WR_x_HOLD: phy_cmd_valid=0 but phy_wdata_oe=1 -- 1-cycle DQ hold after
  // CMD_WR so the SDRAM model reads valid data (CMD_REG_ON_CLK_SH=1 lag).
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE         = 3'd0,
    ST_WR_LOW       = 3'd1,
    ST_WR_LOW_HOLD  = 3'd2,
    ST_WR_HIGH      = 3'd3,
    ST_WR_HIGH_HOLD = 3'd4,
    ST_RD_LOW       = 3'd5,
    ST_RD_HIGH      = 3'd6,
    ST_RD_WAIT      = 3'd7
  } state_e;

  state_e                       state_r;
  logic [ADDR_WIDTH-1:0]        addr_r;
  logic [WORD_DATA_WIDTH-1:0]   wdata_r;
  logic                         rsp_cnt_r;

  // -------------------------------------------------------------------------
  // Read assembler
  // -------------------------------------------------------------------------
  logic hw_valid_w, hw_first_w, asm_word_valid;
  logic [WORD_DATA_WIDTH-1:0] asm_word_data;

  read_word_assembler #(
    .SDRAM_DATA_WIDTH(SDRAM_DATA_WIDTH),
    .WORD_DATA_WIDTH (WORD_DATA_WIDTH)
  ) u_asm (
    .clk       (clk),
    .rstn      (rstn),
    .hw_valid  (hw_valid_w),
    .hw_data   (phy_rdata),
    .hw_first  (hw_first_w),
    .word_valid(asm_word_valid),
    .word_data (asm_word_data)
  );

  assign rsp_valid = asm_word_valid;
  assign rsp_rdata = asm_word_data;

  // -------------------------------------------------------------------------
  // Combinatorial outputs
  // -------------------------------------------------------------------------
  always_comb begin
    req_ready     = (state_r == ST_IDLE);
    phy_cmd_valid = 1'b0;
    phy_cmd_write = 1'b0;
    phy_cmd_addr  = addr_r;
    phy_wdata     = '0;
    phy_wdata_oe  = 1'b0;
    hw_valid_w    = 1'b0;
    hw_first_w    = 1'b0;

    case (state_r)
      ST_WR_LOW: begin
        phy_cmd_valid = 1'b1;
        phy_cmd_write = 1'b1;
        phy_cmd_addr  = addr_r;
        phy_wdata     = wdata_r[SDRAM_DATA_WIDTH-1:0];
        phy_wdata_oe  = 1'b1;
      end
      ST_WR_LOW_HOLD: begin
        phy_cmd_addr  = addr_r;
        phy_wdata     = wdata_r[SDRAM_DATA_WIDTH-1:0];
        phy_wdata_oe  = 1'b1;
      end
      ST_WR_HIGH: begin
        phy_cmd_valid = 1'b1;
        phy_cmd_write = 1'b1;
        phy_cmd_addr  = addr_r + 1'b1;
        phy_wdata     = wdata_r[WORD_DATA_WIDTH-1:SDRAM_DATA_WIDTH];
        phy_wdata_oe  = 1'b1;
      end
      ST_WR_HIGH_HOLD: begin
        phy_cmd_addr  = addr_r + 1'b1;
        phy_wdata     = wdata_r[WORD_DATA_WIDTH-1:SDRAM_DATA_WIDTH];
        phy_wdata_oe  = 1'b1;
      end
      ST_RD_LOW: begin
        phy_cmd_valid = 1'b1;
        phy_cmd_write = 1'b0;
        phy_cmd_addr  = addr_r;
      end
      ST_RD_HIGH: begin
        phy_cmd_valid = 1'b1;
        phy_cmd_write = 1'b0;
        phy_cmd_addr  = addr_r + 1'b1;
      end
      ST_RD_WAIT: begin
        hw_valid_w = phy_rvalid;
        hw_first_w = ~rsp_cnt_r;
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // State register
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_r   <= ST_IDLE;
      addr_r    <= '0;
      wdata_r   <= '0;
      rsp_cnt_r <= 1'b0;
    end else begin
      case (state_r)
        ST_IDLE: begin
          if (req_valid) begin
            addr_r  <= req_addr;
            wdata_r <= req_wdata;
            state_r <= req_write ? ST_WR_LOW : ST_RD_LOW;
          end
        end
        ST_WR_LOW:       if (phy_cmd_ready) state_r <= ST_WR_LOW_HOLD;
        ST_WR_LOW_HOLD:  state_r <= ST_WR_HIGH;
        ST_WR_HIGH:      if (phy_cmd_ready) state_r <= ST_WR_HIGH_HOLD;
        ST_WR_HIGH_HOLD: state_r <= ST_IDLE;
        ST_RD_LOW:       if (phy_cmd_ready) state_r <= ST_RD_HIGH;
        ST_RD_HIGH: begin
          if (phy_cmd_ready) begin
            state_r   <= ST_RD_WAIT;
            rsp_cnt_r <= 1'b0;
          end
        end
        ST_RD_WAIT: begin
          if (phy_rvalid) begin
            rsp_cnt_r <= ~rsp_cnt_r;
            if (rsp_cnt_r) state_r <= ST_IDLE;
          end
        end
        default: state_r <= ST_IDLE;
      endcase
    end
  end

endmodule

`endif // NATIVE_WORD_PORT_SV
