# AUTO-GENERATED - DO NOT EDIT

# -------------------------------------------------------------------------
# Primary clocks
# -------------------------------------------------------------------------
create_clock -name sys_clk -period 20.000 [get_ports { board:sys_clk }]
set_clock_uncertainty 0.100 [get_clocks { sys_clk }]

# -------------------------------------------------------------------------
# Generated clocks
# -------------------------------------------------------------------------
create_generated_clock \
  -name clk_100mhz \
  -source [get_pins { u_clkpll|c0 }] \
  -multiply_by 2 \
  -divide_by 1 \
  [get_pins { u_clkpll|c0 }]
create_generated_clock \
  -name clk_100mhz_sh \
  -source [get_pins { u_clkpll|c1 }] \
  -multiply_by 2 \
  -divide_by 1 \
  [get_pins { u_clkpll|c1 }]
# phase_shift_ps=-3000


# -------------------------------------------------------------------------
# Clock groups
# -------------------------------------------------------------------------
set_clock_groups -exclusive  -group { sys_clk }  -group { clk_100mhz clk_100mhz_sh }

# -------------------------------------------------------------------------
# Derived uncertainty
# -------------------------------------------------------------------------
derive_clock_uncertainty


# -------------------------------------------------------------------------
# False paths
# -------------------------------------------------------------------------
set_false_path -from [get_ports { board:sys_reset_n }] ; # Async reset for domain sys_clkset_false_path -from [get_clocks { sys_clk }] -to [get_clocks { clk_100mhz }] ; # CDC reset sync: sys_clk -> clk_100mhz (2-stage FF)

