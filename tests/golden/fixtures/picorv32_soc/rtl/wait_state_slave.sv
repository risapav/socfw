`default_nettype none

module wait_state_slave #(
  parameter int DELAY = 3
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
);

  logic [$clog2(DELAY+1)-1:0] counter;
  logic pending;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      counter <= '0;
      pending <= 1'b0;
    end else begin
      if (bus.valid && !pending) begin
        pending <= 1'b1;
        counter <= DELAY[$clog2(DELAY+1)-1:0];
      end else if (pending) begin
        if (counter != 0)
          counter <= counter - 1'b1;
        else
          pending <= 1'b0;
      end
    end
  end

  always_comb begin
    bus.ready = pending && (counter == 0);
    bus.rdata = 32'h1234_5678;
  end

endmodule

`default_nettype wire
