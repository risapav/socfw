`default_nettype none

module simple_bus_fabric #(
  parameter int NSLAVES = 1,
  parameter logic [NSLAVES*32-1:0] BASE_ADDR = '0,
  parameter logic [NSLAVES*32-1:0] ADDR_MASK = '0
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave  m_bus,
  bus_if.master s_bus [NSLAVES]
);

  logic [NSLAVES-1:0] sel;

  genvar i;
  generate
    for (i = 0; i < NSLAVES; i++) begin : g_decode
      wire [31:0] base = BASE_ADDR[i*32 +: 32];
      wire [31:0] mask = ADDR_MASK[i*32 +: 32];
      assign sel[i] = ((m_bus.addr & ~mask) == (base & ~mask));
    end
  endgenerate

  always_comb begin
    m_bus.ready = 1'b0;
    m_bus.rdata = 32'h0;

    for (int j = 0; j < NSLAVES; j++) begin
      s_bus[j].addr  = m_bus.addr;
      s_bus[j].wdata = m_bus.wdata;
      s_bus[j].be    = m_bus.be;
      s_bus[j].we    = m_bus.we;
      s_bus[j].valid = m_bus.valid & sel[j];

      if (sel[j]) begin
        m_bus.ready = s_bus[j].ready;
        m_bus.rdata = s_bus[j].rdata;
      end
    end
  end

endmodule : simple_bus_fabric
`default_nettype wire
