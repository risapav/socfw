`default_nettype none

module dummy_cpu (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.master bus
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE_GPIO,
    S_DONE
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state <= S_IDLE;
    end else begin
      case (state)
        S_IDLE:
          state <= S_WRITE_GPIO;
        S_WRITE_GPIO:
          if (bus.ready)
            state <= S_DONE;
        default:
          state <= S_DONE;
      endcase
    end
  end

  always_comb begin
    bus.addr  = 32'h4000_0000;
    bus.wdata = 32'h0000_0015;
    bus.be    = 4'hF;
    bus.we    = 1'b0;
    bus.valid = 1'b0;

    if (state == S_WRITE_GPIO) begin
      bus.we    = 1'b1;
      bus.valid = 1'b1;
    end
  end

endmodule
`default_nettype wire
