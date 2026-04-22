`default_nettype none

module simple_bus_error_slave (
  bus_if.slave bus
);

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = 32'hDEAD_BEEF;
  end

endmodule : simple_bus_error_slave

`default_nettype wire
