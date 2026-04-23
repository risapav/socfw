// AUTO-GENERATED - DO NOT EDIT
`default_nettype none

module soc_top (
  input  wire SYS_CLK,
  input  wire RESET_N,
  output wire [5:0] ONB_LEDS
);

  // Internal wires
  wire cpu_irq; // CPU IRQ bus  wire irq_gpio0_changed; // IRQ source gpio0
  // Interface instances
  bus_if if_cpu0_main (); // master endpoint on main  bus_if if_ram_main (); // slave endpoint on main  bus_if if_gpio0_main (); // slave endpoint on main  bus_if if_error_main (); // error slave for main


  // Bus fabrics
  simple_bus_fabric #(
    .NSLAVES(2),
    .BASE_ADDR("{ 32'h40000000, 32'h00000000 }"),
    .ADDR_MASK("{ 32'h00000FFF, 32'h0000FFFF }")
  ) u_fabric_main (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N)
    ,.m_bus(if_cpu0_main.slave)
    ,.s_bus[0](if_ram_main.master)
    ,.s_bus[1](if_gpio0_main.master)
    ,.err_bus(if_error_main.master)
  ); // simple_bus fabric 'main'
  // IRQ combiner
  irq_combiner #(
    .WIDTH(1)
  ) u_irq_combiner (
    .irq_i({      irq_gpio0_changed    }),
    .irq_o(cpu_irq)
  );

  // Module instances
  simple_bus_error_slave u_error_main (
    .bus(if_error_main.slave)
  ); // error slave for main  dummy_cpu u_cpu0 (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .irq_i(cpu_irq),
    .bus(if_cpu0_main.master)
  ); // dummy_cpu  soc_ram #(
    .RAM_BYTES(65536),
    .INIT_FILE("")
  ) u_ram (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .bus(if_ram_main.slave)
  ); // RAM @ 0x00000000  gpio0_shell u_gpio0 (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .gpio_o(ONB_LEDS),
    .irq_changed(irq_gpio0_changed),
    .bus(if_gpio0_main.slave)
  );
endmodule : soc_top
`default_nettype wire
