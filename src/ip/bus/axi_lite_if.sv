interface axi_lite_if;
  logic [31:0] awaddr;
  logic        awvalid;
  logic        awready;

  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid;
  logic        wready;

  logic [1:0]  bresp;
  logic        bvalid;
  logic        bready;

  logic [31:0] araddr;
  logic        arvalid;
  logic        arready;

  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  modport master (
    output awaddr, output awvalid, input  awready,
    output wdata,  output wstrb,   output wvalid, input wready,
    input  bresp,  input  bvalid,  output bready,
    output araddr, output arvalid, input  arready,
    input  rdata,  input  rresp,   input  rvalid, output rready
  );

  modport slave (
    input  awaddr, input  awvalid, output awready,
    input  wdata,  input  wstrb,   input  wvalid, output wready,
    output bresp,  output bvalid,  input  bready,
    input  araddr, input  arvalid, output arready,
    output rdata,  output rresp,   output rvalid, input  rready
  );
endinterface
