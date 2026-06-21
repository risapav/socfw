// @file axi_native_adapter.sv
// @brief AXI-lite to native_word_port adapter with protocol guards.
// @details Translates AXI-lite 32-bit transactions to native_word_port requests.
//          Single outstanding transaction only. No bursts. Full 32-bit accesses.
//          Address conversion: native_req_addr = axi_addr >> 1 (halfword base).
//          Requires word-aligned AXI addresses (axi_addr[1:0] == 2'b00).
//          Requires full-word WSTRB (4'b1111); partial strobe returns SLVERR.
//          Write path: waits for both AW and W channels before issuing native write.
//          Read path: accepts AR, issues native read, waits for rsp_valid, drives R.
// @param AXI_ADDR_WIDTH    AXI address bus width.
// @param AXI_DATA_WIDTH    AXI data bus width (must be 32 for this version).
// @param NATIVE_ADDR_WIDTH native_word_port address width.
`ifndef AXI_NATIVE_ADAPTER_SV
`define AXI_NATIVE_ADAPTER_SV
`default_nettype none

module axi_native_adapter #(
  parameter int AXI_ADDR_WIDTH    = 24,
  parameter int AXI_DATA_WIDTH    = 32,
  parameter int NATIVE_ADDR_WIDTH = 24
)(
  input  logic        clk,
  input  logic        rstn,

  // AXI write address channel
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic        s_axi_awvalid,
  output logic        s_axi_awready,

  // AXI write data channel
  input  logic [AXI_DATA_WIDTH-1:0] s_axi_wdata,
  input  logic [3:0]  s_axi_wstrb,
  input  logic        s_axi_wvalid,
  output logic        s_axi_wready,

  // AXI write response channel
  output logic [1:0]  s_axi_bresp,
  output logic        s_axi_bvalid,
  input  logic        s_axi_bready,

  // AXI read address channel
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic        s_axi_arvalid,
  output logic        s_axi_arready,

  // AXI read data channel
  output logic [AXI_DATA_WIDTH-1:0] s_axi_rdata,
  output logic [1:0]  s_axi_rresp,
  output logic        s_axi_rvalid,
  input  logic        s_axi_rready,

  // native request (to native_word_port)
  output logic                          native_req_valid,
  input  logic                          native_req_ready,
  output logic                          native_req_write,
  output logic [NATIVE_ADDR_WIDTH-1:0]  native_req_addr,
  output logic [31:0]                   native_req_wdata,

  // native response (from native_word_port)
  input  logic        native_rsp_valid,
  input  logic [31:0] native_rsp_rdata
);

  // -------------------------------------------------------------------------
  // State machine
  // AW_ONLY: AW latched, waiting for W channel
  // W_ONLY:  W latched, waiting for AW channel
  // WR_ISSU: both AW+W latched, driving native write, waiting for handshake
  // BVALID:  write done (or SLVERR short-circuit), driving B response
  // RD_ISSU: AR latched, driving native read, waiting for handshake
  // RD_WAIT: native read accepted, waiting for native_rsp_valid
  // RVALID:  native response latched (or SLVERR), driving R channel
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE    = 3'd0,
    ST_AW_ONLY = 3'd1,
    ST_W_ONLY  = 3'd2,
    ST_WR_ISSU = 3'd3,
    ST_BVALID  = 3'd4,
    ST_RD_ISSU = 3'd5,
    ST_RD_WAIT = 3'd6,
    ST_RVALID  = 3'd7
  } state_e;

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  state_e                      state_r;
  logic [AXI_ADDR_WIDTH-1:0]   awaddr_r;
  logic [AXI_DATA_WIDTH-1:0]   wdata_r;
  logic [3:0]                  wstrb_r;
  logic [AXI_ADDR_WIDTH-1:0]   araddr_r;
  logic [AXI_DATA_WIDTH-1:0]   rdata_r;
  logic [1:0]                  bresp_r;
  logic [1:0]                  rresp_r;

  // -------------------------------------------------------------------------
  // Combinatorial outputs
  // -------------------------------------------------------------------------
  always_comb begin
    s_axi_awready    = 1'b0;
    s_axi_wready     = 1'b0;
    s_axi_bvalid     = 1'b0;
    s_axi_bresp      = RESP_OKAY;
    s_axi_arready    = 1'b0;
    s_axi_rvalid     = 1'b0;
    s_axi_rresp      = RESP_OKAY;
    s_axi_rdata      = rdata_r;
    native_req_valid = 1'b0;
    native_req_write = 1'b0;
    native_req_addr  = '0;
    native_req_wdata = '0;

    case (state_r)
      ST_IDLE: begin
        if (s_axi_awvalid) begin
          s_axi_awready = 1'b1;
          if (s_axi_wvalid) s_axi_wready = 1'b1;
        end else if (s_axi_wvalid) begin
          s_axi_wready  = 1'b1;
        end else if (s_axi_arvalid) begin
          s_axi_arready = 1'b1;
        end
      end

      ST_AW_ONLY: begin
        if (s_axi_wvalid) s_axi_wready = 1'b1;
      end

      ST_W_ONLY: begin
        if (s_axi_awvalid) s_axi_awready = 1'b1;
      end

      ST_WR_ISSU: begin
        native_req_valid = 1'b1;
        native_req_write = 1'b1;
        native_req_addr  = {1'b0, awaddr_r[AXI_ADDR_WIDTH-1:1]};
        native_req_wdata = wdata_r[31:0];
      end

      ST_BVALID: begin
        s_axi_bvalid = 1'b1;
        s_axi_bresp  = bresp_r;
      end

      ST_RD_ISSU: begin
        native_req_valid = 1'b1;
        native_req_write = 1'b0;
        native_req_addr  = {1'b0, araddr_r[AXI_ADDR_WIDTH-1:1]};
      end

      ST_RD_WAIT: ;

      ST_RVALID: begin
        s_axi_rvalid = 1'b1;
        s_axi_rresp  = rresp_r;
        s_axi_rdata  = rdata_r;
      end

      default: ;
    endcase
  end

  // -------------------------------------------------------------------------
  // State register
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state_r  <= ST_IDLE;
      awaddr_r <= '0;
      wdata_r  <= '0;
      wstrb_r  <= '0;
      araddr_r <= '0;
      rdata_r  <= '0;
      bresp_r  <= RESP_OKAY;
      rresp_r  <= RESP_OKAY;
    end else begin
      case (state_r)
        ST_IDLE: begin
          if (s_axi_awvalid) begin
            awaddr_r <= s_axi_awaddr;
            if (s_axi_wvalid) begin
              wdata_r <= s_axi_wdata;
              wstrb_r <= s_axi_wstrb;
              // protocol guard: alignment + full-word strobe
              if (s_axi_awaddr[1:0] != 2'b00 || s_axi_wstrb != 4'b1111) begin
                bresp_r <= RESP_SLVERR;
                state_r <= ST_BVALID;
              end else begin
                bresp_r <= RESP_OKAY;
                state_r <= ST_WR_ISSU;
              end
            end else begin
              state_r <= ST_AW_ONLY;
            end
          end else if (s_axi_wvalid) begin
            wdata_r <= s_axi_wdata;
            wstrb_r <= s_axi_wstrb;
            state_r <= ST_W_ONLY;
          end else if (s_axi_arvalid) begin
            araddr_r <= s_axi_araddr;
            // protocol guard: alignment
            if (s_axi_araddr[1:0] != 2'b00) begin
              rresp_r <= RESP_SLVERR;
              rdata_r <= '0;
              state_r <= ST_RVALID;
            end else begin
              rresp_r <= RESP_OKAY;
              state_r <= ST_RD_ISSU;
            end
          end
        end

        ST_AW_ONLY: begin
          if (s_axi_wvalid) begin
            wdata_r <= s_axi_wdata;
            wstrb_r <= s_axi_wstrb;
            // protocol guard: stored awaddr + incoming wstrb
            if (awaddr_r[1:0] != 2'b00 || s_axi_wstrb != 4'b1111) begin
              bresp_r <= RESP_SLVERR;
              state_r <= ST_BVALID;
            end else begin
              bresp_r <= RESP_OKAY;
              state_r <= ST_WR_ISSU;
            end
          end
        end

        ST_W_ONLY: begin
          if (s_axi_awvalid) begin
            awaddr_r <= s_axi_awaddr;
            // protocol guard: incoming awaddr + stored wstrb
            if (s_axi_awaddr[1:0] != 2'b00 || wstrb_r != 4'b1111) begin
              bresp_r <= RESP_SLVERR;
              state_r <= ST_BVALID;
            end else begin
              bresp_r <= RESP_OKAY;
              state_r <= ST_WR_ISSU;
            end
          end
        end

        ST_WR_ISSU: begin
          if (native_req_ready) state_r <= ST_BVALID;
        end

        ST_BVALID: begin
          if (s_axi_bready) state_r <= ST_IDLE;
        end

        ST_RD_ISSU: begin
          if (native_req_ready) state_r <= ST_RD_WAIT;
        end

        ST_RD_WAIT: begin
          if (native_rsp_valid) begin
            rdata_r <= native_rsp_rdata;
            rresp_r <= RESP_OKAY;
            state_r <= ST_RVALID;
          end
        end

        ST_RVALID: begin
          if (s_axi_rready) state_r <= ST_IDLE;
        end

        default: state_r <= ST_IDLE;
      endcase
    end
  end

endmodule
`endif // AXI_NATIVE_ADAPTER_SV
