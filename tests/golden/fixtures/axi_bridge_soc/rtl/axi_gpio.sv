`default_nettype none

module axi_gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  axi_lite_if.slave axil,
  output logic [5:0] gpio_o
);

  logic [31:0] reg_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      reg_value <= 32'h0;
    else if (axil.awvalid && axil.wvalid)
      reg_value <= axil.wdata;
  end

  always_comb begin
    axil.awready = 1'b1;
    axil.wready  = 1'b1;
    axil.bresp   = 2'b00;
    axil.bvalid  = axil.awvalid && axil.wvalid;

    axil.arready = 1'b1;
    axil.rdata   = reg_value;
    axil.rresp   = 2'b00;
    axil.rvalid  = axil.arvalid;
  end

  assign gpio_o = reg_value[5:0];

endmodule

`default_nettype wire
