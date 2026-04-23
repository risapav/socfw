`default_nettype none

module dummy_cpu (
  input  wire SYS_CLK,
  input  wire RESET_N,
  input  wire [31:0] irq,
  bus_if.master bus
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE,
    S_DONE
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      state <= S_IDLE;
    else begin
      case (state)
        S_IDLE:  state <= S_WRITE;
        S_WRITE: if (bus.ready) state <= S_DONE;
        default: state <= S_DONE;
      endcase
    end
  end

  always_comb begin
    bus.addr  = 32'h4000_3000;
    bus.wdata = 32'h0000_0015;
    bus.be    = 4'hF;
    bus.we    = 1'b0;
    bus.valid = 1'b0;

    if (state == S_WRITE) begin
      bus.we    = 1'b1;
      bus.valid = 1'b1;
    end
  end

endmodule

`default_nettype wire
