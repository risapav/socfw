# Simulation

The framework generates simulation artifacts as part of every `socfw build` and provides
a `socfw simulate` command for running iverilog-based simulations.

## What gets generated

`socfw build` always produces two simulation files in `build/sim/`:

| File | Description |
|---|---|
| `sim/tb_soc_top.sv` | Auto-generated testbench |
| `sim/files.f` | iverilog filelist (`-f`) |

No extra flag is needed — simulation files are part of the standard build output.

## Auto-generated testbench

The testbench `tb_soc_top.sv` is generated from `timing_config.yaml` and the board descriptor:

```systemverilog
// AUTO-GENERATED - DO NOT EDIT
`timescale 1ns/1ps

module tb_soc_top;

  localparam real CLK_HALF_NS = 10.0000;  // from timing_config.yaml primary clock

  logic SYS_CLK;
  logic RESET_N;          // input ports → logic (driven by testbench)
  wire  [4:0] VGA_R;      // output ports → wire (driven by DUT)
  ...

  soc_top dut (
    .SYS_CLK(SYS_CLK),
    .RESET_N(RESET_N),
    .VGA_R(VGA_R),
    ...
  );

  always #(CLK_HALF_NS) SYS_CLK = ~SYS_CLK;

  initial begin
    $dumpfile("sim/wave.vcd");
    $dumpvars(0, dut);
    SYS_CLK = 0;
    RESET_N = 0;           // assert reset (active-low from board descriptor)
    repeat(10) @(posedge SYS_CLK);
    RESET_N = 1;           // release reset
    repeat(1000) @(posedge SYS_CLK);
    $display("SIM OK");
    $finish;
  end

endmodule : tb_soc_top
```

**What the generator uses:**
- `timing_config.yaml` → `primary_clocks[0].period_ns` → `CLK_HALF_NS`
- `timing_config.yaml` → `primary_clocks[0].source_port` → clock port name
- Board descriptor → `sys_reset.top_name` → reset port name
- Board descriptor → `sys_reset.active_low` → reset polarity
- `RtlTop.ports` → all DUT port declarations and connections

## Filelist `sim/files.f`

```text
rtl/soc_top.sv
/abs/path/to/ip/rtl/cdc_reset_synchronizer.sv
/abs/path/to/ip/rtl/video/vga_rgb565_stream.sv
...
sim/tb_soc_top.sv
```

Rules:
- `rtl/soc_top.sv` — relative to `out_dir` (where iverilog runs)
- IP RTL files — absolute paths (from IP descriptor `artifacts.synthesis`)
- `.qip` vendor files are **excluded** (not valid for iverilog)
- `simulation:` artifacts from IP descriptors are included
- `sim/tb_soc_top.sv` appended last (after it's generated)

## Running simulation

```sh
socfw simulate project.yaml --out build
```

This builds the project and runs:

```sh
iverilog -g2012 -s tb_soc_top -o sim/sim.vvp -f sim/files.f
vvp sim/sim.vvp
```

Output:
```
[sim] build/sim/tb_soc_top.sv
[sim] build/sim/files.f
SIM OK
[vcd] build/sim/wave.vcd
```

### Options

```sh
socfw simulate project.yaml --out build --no-vcd   # disable waveform capture
```

| Option | Default | Description |
|---|---|---|
| `--out DIR` | `build` | Output directory |
| `--vcd` | on | Capture VCD waveform to `sim/wave.vcd` |
| `--no-vcd` | — | Disable VCD capture |

### If iverilog is not installed

`socfw simulate` exits with code 0 and prints:

```
WARNING SIM001 simulation
iverilog not found, skipping simulation
```

Install iverilog:
```sh
# Fedora / RHEL
sudo dnf install iverilog

# Ubuntu / Debian
sudo apt install iverilog

# macOS
brew install icarus-verilog
```

## Viewing waveforms

Open `sim/wave.vcd` with GTKWave or any VCD viewer:

```sh
gtkwave build/sim/wave.vcd
```

## Custom testbench

The auto-generated `tb_soc_top.sv` is a smoke-test scaffold. For detailed testing,
create a manual testbench in the project's `tb/` directory:

```
my_project/
  tb/
    tb_soc_top.sv    ← replaces the auto-generated one
```

`TestbenchStager` copies all `.sv` files from `tb/` into `sim/` before simulation,
overwriting the generated testbench.

## Simulation in IP descriptors

IP descriptors can list simulation-specific RTL files separately from synthesis files:

```yaml
artifacts:
  synthesis:
    - rtl/my_module.sv
  simulation:
    - rtl/sim/my_module_model.sv   # simulation model, excluded from Quartus
```

Files listed under `simulation:` are included in `sim/files.f` but not in `hal/files.tcl`.

## Simulation error codes

| Code | Severity | Meaning |
|---|---|---|
| `SIM001` | WARNING | `iverilog` not found on PATH |
| `SIM002` | ERROR | `iverilog` compile failed (check port connections, missing files) |
| `SIM003` | ERROR | `vvp` simulation failed (check `$finish` / runtime assertions) |
