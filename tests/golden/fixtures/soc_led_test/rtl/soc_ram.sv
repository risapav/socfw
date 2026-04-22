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

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  always_ff @(posedge SYS_CLK) begin
    if (bus.valid && bus.we) begin
      mem[word_addr] <= bus.wdata;
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = mem[word_addr];
  end

endmodule
`default_nettype wire
