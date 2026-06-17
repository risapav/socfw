/**
 * @file  axil_regfile.sv
 * @brief Generic AXI-Lite register bank with configurable per-register type.
 * @param NUM_REGS    Number of 32-bit registers; register i is at byte offset i*4.
 * @param REG_TYPES   Packed 2-bit type per register, register 0 at bits [1:0].
 *                    Use axil_reg_type_e values: AXIL_RO=2'b00, AXIL_RW=2'b01,
 *                    AXIL_W1C=2'b10, AXIL_PULSE=2'b11.
 * @param RESET_VALS  Packed 32-bit reset values, register 0 at bits [31:0].
 *                    Applied on rst_ni de-assertion; effective for RW and W1C registers.
 * @details
 *   hw_rdata_i[i*32 +: 32]:
 *     AXIL_RO    -- value returned on AXI read (combinatorial pass-through).
 *     AXIL_W1C   -- bits OR-d into the stored sticky value every clock cycle;
 *                   drive a one-cycle pulse to latch a new error bit.
 *   hw_wdata_o[i*32 +: 32]:
 *     AXIL_RW    -- current stored register value.
 *     AXIL_W1C   -- current stored sticky value.
 *     AXIL_PULSE -- data from the last SW write (held until the next write).
 *   hw_we_o[i]:
 *     One-cycle strobe asserted when SW writes to register i (all types).
 *   Out-of-range reads return 32'h0; out-of-range writes return AXI OKAY silently.
 */
`ifndef AXIL_REGFILE_SV
`define AXIL_REGFILE_SV

`default_nettype none

import axi_pkg::*;

module axil_regfile #(
  parameter int                NUM_REGS   = 4,
  parameter [NUM_REGS*2-1:0]   REG_TYPES  = '0,
  parameter [NUM_REGS*32-1:0]  RESET_VALS = '0
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  axi4lite_if.slave               s_axil,
  input  logic [NUM_REGS*32-1:0]  hw_rdata_i,
  output logic [NUM_REGS*32-1:0]  hw_wdata_o,
  output logic [NUM_REGS-1:0]     hw_we_o
);

  localparam int ADDR_BITS      = $clog2(NUM_REGS > 1 ? NUM_REGS : 2);
  // One extra bit prevents truncation when NUM_REGS == 2^ADDR_BITS.
  localparam int ADDR_BITS_WIDE = ADDR_BITS + 1;

  // Read-data mux: each gen_reg slice drives its element via continuous assign.
  logic [31:0] rdata_mux [NUM_REGS];

  // --------------------------------------------------------------------------
  // Write path
  // --------------------------------------------------------------------------
  logic                  aw_pend_r, w_pend_r, b_valid_r;
  logic [31:0]           awaddr_r, wdata_r;
  logic [3:0]            wstrb_r;
  logic [ADDR_BITS-1:0]  wr_idx_w;
  logic                  wr_fire_w;

  assign s_axil.AWREADY = ~aw_pend_r;
  assign s_axil.WREADY  = ~w_pend_r;
  assign s_axil.BVALID  = b_valid_r;
  assign s_axil.BRESP   = AXI_RESP_OKAY;

  assign wr_idx_w  = awaddr_r[2 +: ADDR_BITS];
  assign wr_fire_w = aw_pend_r & w_pend_r & ~b_valid_r;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pend_r <= 1'b0;
      w_pend_r  <= 1'b0;
      b_valid_r <= 1'b0;
      awaddr_r  <= '0;
      wdata_r   <= '0;
      wstrb_r   <= '0;
    end else begin
      if (s_axil.AWVALID && ~aw_pend_r) begin
        awaddr_r  <= 32'(s_axil.AWADDR);
        aw_pend_r <= 1'b1;
      end
      if (s_axil.WVALID && ~w_pend_r) begin
        wdata_r  <= s_axil.WDATA;
        wstrb_r  <= s_axil.WSTRB;
        w_pend_r <= 1'b1;
      end
      if (wr_fire_w) begin
        aw_pend_r <= 1'b0;
        w_pend_r  <= 1'b0;
        b_valid_r <= 1'b1;
      end
      if (b_valid_r && s_axil.BREADY)
        b_valid_r <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Per-register behavior
  // --------------------------------------------------------------------------
  generate
    genvar i;
    for (i = 0; i < NUM_REGS; i++) begin : gen_reg
      localparam logic [1:0]  RTYPE = REG_TYPES[i*2 +: 2];
      localparam logic [31:0] RVAL  = RESET_VALS[i*32 +: 32];

      logic reg_sel_w;
      assign reg_sel_w  = wr_fire_w & (wr_idx_w == ADDR_BITS'(i));
      assign hw_we_o[i] = reg_sel_w;

      if (RTYPE == 2'(AXIL_RW)) begin : g_rw
        logic [31:0] val_r;
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            val_r <= RVAL;
          end else if (reg_sel_w) begin
            for (int b = 0; b < 4; b++)
              if (wstrb_r[b]) val_r[b*8 +: 8] <= wdata_r[b*8 +: 8];
          end
        end
        assign rdata_mux[i]           = val_r;
        assign hw_wdata_o[i*32 +: 32] = val_r;

      end else if (RTYPE == 2'(AXIL_W1C)) begin : g_w1c
        logic [31:0] val_r;
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            val_r <= RVAL;
          end else begin
            for (int b = 0; b < 4; b++) begin
              if (reg_sel_w && wstrb_r[b])
                val_r[b*8 +: 8] <= (val_r[b*8 +: 8] | hw_rdata_i[i*32 + b*8 +: 8]) &
                                   ~wdata_r[b*8 +: 8];
              else
                val_r[b*8 +: 8] <= val_r[b*8 +: 8] | hw_rdata_i[i*32 + b*8 +: 8];
            end
          end
        end
        assign rdata_mux[i]           = val_r;
        assign hw_wdata_o[i*32 +: 32] = val_r;

      end else if (RTYPE == 2'(AXIL_PULSE)) begin : g_pulse
        logic [31:0] val_r;
        always_ff @(posedge clk_i or negedge rst_ni) begin
          if (!rst_ni) begin
            val_r <= 32'h0;
          end else if (reg_sel_w) begin
            val_r <= wdata_r;
          end
        end
        assign rdata_mux[i]           = 32'h0;
        assign hw_wdata_o[i*32 +: 32] = val_r;

      end else begin : g_ro // AXIL_RO
        assign rdata_mux[i]           = hw_rdata_i[i*32 +: 32];
        assign hw_wdata_o[i*32 +: 32] = 32'h0;
      end

    end
  endgenerate

  // --------------------------------------------------------------------------
  // Read path: 1-cycle latency
  // --------------------------------------------------------------------------
  logic [ADDR_BITS-1:0]      rd_idx_w;
  logic [ADDR_BITS_WIDE-1:0] rd_idx_wide_w;
  logic                      r_valid_r;
  logic [31:0]               rdata_r;

  assign s_axil.ARREADY = ~r_valid_r;
  assign s_axil.RVALID  = r_valid_r;
  assign s_axil.RDATA   = rdata_r;
  assign s_axil.RRESP   = AXI_RESP_OKAY;

  assign rd_idx_w      = s_axil.ARADDR[2 +: ADDR_BITS];
  assign rd_idx_wide_w = {1'b0, rd_idx_w};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_valid_r <= 1'b0;
      rdata_r   <= '0;
    end else begin
      if (s_axil.ARVALID && ~r_valid_r) begin
        r_valid_r <= 1'b1;
        rdata_r   <= (rd_idx_wide_w < ADDR_BITS_WIDE'(NUM_REGS)) ?
                     rdata_mux[rd_idx_w] : 32'h0;
      end
      if (r_valid_r && s_axil.RREADY)
        r_valid_r <= 1'b0;
    end
  end

endmodule

`endif // AXIL_REGFILE_SV
