interface bus_if;
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic [3:0]  be;
  logic        we;
  logic        valid;
  logic        ready;

  modport master (
    output addr, output wdata, output be, output we, output valid,
    input  rdata, input ready
  );

  modport slave (
    input  addr, input wdata, input be, input we, input valid,
    output rdata, output ready
  );
endinterface
