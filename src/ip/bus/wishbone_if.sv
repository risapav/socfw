interface wishbone_if;
  logic [31:0] adr;
  logic [31:0] dat_w;
  logic [31:0] dat_r;
  logic [3:0]  sel;
  logic        we;
  logic        cyc;
  logic        stb;
  logic        ack;

  modport master (
    output adr, output dat_w, output sel, output we, output cyc, output stb,
    input  dat_r, input ack
  );

  modport slave (
    input  adr, input dat_w, input sel, input we, input cyc, input stb,
    output dat_r, output ack
  );
endinterface
