`default_nettype none

module simple_bus_to_wishbone_bridge (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave       sbus,
  wishbone_if.master m_wb
);

  typedef enum logic [0:0] {
    S_IDLE,
    S_WAIT_ACK
  } state_t;

  state_t state;

  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_be;
  logic        req_we;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state     <= S_IDLE;
      req_addr  <= 32'h0;
      req_wdata <= 32'h0;
      req_be    <= 4'h0;
      req_we    <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (sbus.valid) begin
            req_addr  <= sbus.addr;
            req_wdata <= sbus.wdata;
            req_be    <= sbus.be;
            req_we    <= sbus.we;
            state     <= S_WAIT_ACK;
          end
        end
        S_WAIT_ACK: begin
          if (m_wb.ack)
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    sbus.ready = 1'b0;
    sbus.rdata = m_wb.dat_r;

    m_wb.adr   = (state == S_IDLE) ? sbus.addr  : req_addr;
    m_wb.dat_w = (state == S_IDLE) ? sbus.wdata : req_wdata;
    m_wb.sel   = (state == S_IDLE) ? sbus.be    : req_be;
    m_wb.we    = (state == S_IDLE) ? sbus.we    : req_we;
    m_wb.cyc   = (state == S_IDLE) ? sbus.valid : 1'b1;
    m_wb.stb   = (state == S_IDLE) ? sbus.valid : 1'b1;

    if (state == S_WAIT_ACK && m_wb.ack)
      sbus.ready = 1'b1;
  end

endmodule

`default_nettype wire
