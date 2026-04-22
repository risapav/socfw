`default_nettype none

module soc_ram #(
  parameter int RAM_BYTES = 65536,
  parameter string INIT_FILE = ""
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
);

  localparam int WORDS = RAM_BYTES / 4;
  logic [31:0] mem [0:WORDS-1];
  wire [31:2] word_addr = bus.addr[31:2];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1)
      mem[i] = 32'h00000013; // NOP for RISC-V

    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge SYS_CLK) begin
    if (bus.valid && bus.we) begin
      if (bus.be[0]) mem[word_addr][7:0]   <= bus.wdata[7:0];
      if (bus.be[1]) mem[word_addr][15:8]  <= bus.wdata[15:8];
      if (bus.be[2]) mem[word_addr][23:16] <= bus.wdata[23:16];
      if (bus.be[3]) mem[word_addr][31:24] <= bus.wdata[31:24];
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = mem[word_addr];
  end

endmodule

`default_nettype wire
