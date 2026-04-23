`default_nettype none

module simple_bus_to_axi_lite_bridge (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave       sbus,
  axi_lite_if.master m_axil
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE_RESP,
    S_READ_RESP
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE: begin
          if (sbus.valid && sbus.we && m_axil.awready && m_axil.wready)
            state <= S_WRITE_RESP;
          else if (sbus.valid && !sbus.we && m_axil.arready)
            state <= S_READ_RESP;
        end
        S_WRITE_RESP: begin
          if (m_axil.bvalid)
            state <= S_IDLE;
        end
        S_READ_RESP: begin
          if (m_axil.rvalid)
            state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    sbus.ready = 1'b0;
    sbus.rdata = 32'h0;

    m_axil.awaddr  = sbus.addr;
    m_axil.awvalid = (state == S_IDLE) && sbus.valid && sbus.we;

    m_axil.wdata   = sbus.wdata;
    m_axil.wstrb   = sbus.be;
    m_axil.wvalid  = (state == S_IDLE) && sbus.valid && sbus.we;

    m_axil.bready  = 1'b1;

    m_axil.araddr  = sbus.addr;
    m_axil.arvalid = (state == S_IDLE) && sbus.valid && !sbus.we;

    m_axil.rready  = 1'b1;

    if (state == S_WRITE_RESP && m_axil.bvalid) begin
      sbus.ready = 1'b1;
      sbus.rdata = 32'h0;
    end

    if (state == S_READ_RESP && m_axil.rvalid) begin
      sbus.ready = 1'b1;
      sbus.rdata = m_axil.rdata;
    end
  end

endmodule

`default_nettype wire
