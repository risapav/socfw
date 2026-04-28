`default_nettype none

// Demo: cycles through all hex values 0-F on all digits.
// A walking dot shifts across digits every ~1s. The hex counter
// advances at TICK_HZ so all values are visible within seconds.
module seven_seg_demo #(
  parameter int CLOCK_FREQ_HZ = 50_000_000,
  parameter int NUM_DIGITS    = 6,
  parameter int TICK_HZ       = 4   // display update rate
)(
  input  logic clk_i,
  input  logic rst_ni,

  output logic [NUM_DIGITS*4-1:0] digits_o,
  output logic [NUM_DIGITS-1:0]   dots_o
);

  localparam int TickDiv      = CLOCK_FREQ_HZ / TICK_HZ;
  localparam int PrescrWidth  = $clog2(TickDiv);
  localparam int CntWidth     = NUM_DIGITS * 4;

  logic [PrescrWidth-1:0]  prescaler;
  logic                    tick;
  logic [CntWidth-1:0]     counter;
  logic [2:0]              dot_phase;   // counts 0..3, one dot step per 4 ticks (~1s)
  logic [NUM_DIGITS-1:0]   dot_pos;

  // Prescaler → tick at TICK_HZ
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      prescaler <= '0;
      tick      <= 1'b0;
    end else if (prescaler == PrescrWidth'(TickDiv - 1)) begin
      prescaler <= '0;
      tick      <= 1'b1;
    end else begin
      prescaler <= prescaler + 1'b1;
      tick      <= 1'b0;
    end
  end

  // Hex counter — digit[0] = bits[3:0], digit[5] = bits[23:20]
  always_ff @(posedge clk_i) begin
    if (!rst_ni)
      counter <= '0;
    else if (tick)
      counter <= counter + 1;
  end

  // Walking dot: advances one position every 4 ticks (≈1 s)
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      dot_phase <= '0;
      dot_pos   <= NUM_DIGITS'(1);          // start: only digit 0 dot lit
    end else if (tick) begin
      if (dot_phase == 3'd3) begin
        dot_phase <= '0;
        // rotate left (dot walks left → rightmost = digit 0)
        dot_pos <= {dot_pos[NUM_DIGITS-2:0], dot_pos[NUM_DIGITS-1]};
      end else begin
        dot_phase <= dot_phase + 1'b1;
      end
    end
  end

  assign digits_o = counter;
  assign dots_o   = dot_pos;

endmodule

`default_nettype wire
