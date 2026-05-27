`timescale 1ns/1ps

// Smoke test for ethernet_test.sv top-level
//
// T1: eth_rst_no == 0 immediately after reset release (PHY extender counting)
// T2: after counter forced to 21'h1FFFFF, eth_rst_no goes 1
// T3: eth_gtx_clk_o tracks eth_tx_clk_i (PLL clock forwarding)
// T4: eth_mdc_o == 1'b0 (MDIO clock inactive)
// T5: eth_mdio_io === 1'bz (MDIO data high-Z)
//
// Run (from sim/):
//   vlog -sv -suppress 2892 \
//        ../rtl/crc.sv ../rtl/ipsend.sv ../rtl/ipreceive.sv \
//        ../rtl/udp.sv ../rtl/ram.sv ../rtl/eth_status_leds.sv \
//        ../rtl/ethernet_test.sv \
//        integration/tb_ethernet_test_top_smoke.sv
//   vsim -c -do "run -all; quit" tb_ethernet_test_top_smoke

module tb_ethernet_test_top_smoke;

  int fail_count = 0;

  logic       clk     = 1'b0;  // eth_rx_clk_i @ 125 MHz
  logic       pll_clk = 1'b0;  // eth_tx_clk_i @ 125 MHz (PLL v HW, priame hodiny v sim)
  logic       sys_clk = 1'b0;  // sys_clk_i @ 50 MHz
  logic       rst_ni;

  logic       eth_mdc_o;
  wire        eth_mdio_io;
  logic       eth_rx_dv_i    = 1'b0;
  logic       eth_rx_er_i    = 1'b0;
  logic [7:0] eth_rx_data_i  = 8'h00;
  logic       eth_rst_no;
  logic       eth_gtx_clk_o;
  logic       eth_tx_en_o;
  logic       eth_tx_er_o;
  logic [7:0] eth_tx_data_o;

  always #4  clk     = ~clk;      // 125 MHz
  always #4  pll_clk = ~pll_clk;  // 125 MHz (simuluje PLL vystup)
  always #10 sys_clk = ~sys_clk;  // 50 MHz

  ethernet_test dut (
    .rst_ni        (rst_ni),
    .sys_clk_i     (sys_clk),
    .eth_tx_clk_i  (pll_clk),
    .eth_rst_no    (eth_rst_no),
    .eth_mdc_o     (eth_mdc_o),
    .eth_mdio_io   (eth_mdio_io),
    .eth_rx_clk_i  (clk),
    .eth_rx_dv_i   (eth_rx_dv_i),
    .eth_rx_er_i   (eth_rx_er_i),
    .eth_rx_data_i (eth_rx_data_i),
    .eth_gtx_clk_o (eth_gtx_clk_o),
    .eth_tx_en_o   (eth_tx_en_o),
    .eth_tx_er_o   (eth_tx_er_o),
    .eth_tx_data_o (eth_tx_data_o)
  );

  task automatic chk1(input string tag, input logic got, input logic exp);
    if (got !== exp) begin
      $display("FAIL %s: got=%b exp=%b", tag, got, exp);
      fail_count++;
    end else begin
      $display("PASS %s: %b", tag, got);
    end
  endtask

  initial begin
    rst_ni = 1'b0;
    repeat (4) @(posedge sys_clk); #1;
    rst_ni = 1'b1;
    repeat (2) @(posedge sys_clk); #1;

    // -- T1: PHY reset extender still counting after release --
    $display("-- T1: eth_rst_no=0 (PHY extender active) --");
    chk1("T1 eth_rst_no=0", eth_rst_no, 1'b0);

    // -- T2: force counter to 21'h1FFFFF, &cnt fires on next posedge of sys_clk --
    $display("-- T2: eth_rst_no=1 after counter overflow --");
    force dut.phy_rst_cnt_q = 21'h1FFFFF;
    @(posedge sys_clk); #1;
    release dut.phy_rst_cnt_q;
    chk1("T2 eth_rst_no=1", eth_rst_no, 1'b1);

    // -- T3: eth_gtx_clk_o == eth_tx_clk_i (PLL clock forwarding) --
    $display("-- T3: eth_gtx_clk_o tracks eth_tx_clk_i (PLL) --");
    @(posedge pll_clk); #1;
    chk1("T3 gtx_clk=1 on posedge", eth_gtx_clk_o, 1'b1);
    @(negedge pll_clk); #1;
    chk1("T3 gtx_clk=0 on negedge", eth_gtx_clk_o, 1'b0);

    // -- T4: eth_mdc_o == 0 --
    $display("-- T4: eth_mdc_o=0 --");
    chk1("T4 eth_mdc_o=0", eth_mdc_o, 1'b0);

    // -- T5: eth_mdio_io === Z (DUT drives 1'bz, TB leaves undriven) --
    $display("-- T5: eth_mdio_io=Z --");
    if (eth_mdio_io !== 1'bz) begin
      $display("FAIL T5 eth_mdio_io: got=%b exp=Z", eth_mdio_io);
      fail_count++;
    end else begin
      $display("PASS T5 eth_mdio_io: Z");
    end

    if (fail_count == 0)
      $display("\n       ALL PASSED (0 failures)");
    else
      $display("\n       FAILED (%0d failures)", fail_count);

    $finish;
  end

endmodule
