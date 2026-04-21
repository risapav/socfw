Super. Ideme na:

# PicoRV32 + `simple_bus` wrapper + firmware build flow + BIN/HEX integrácia

Cieľ tohto kroku je dostať framework do bodu, kde vieš mať:

* **reálny CPU descriptor**
* **reálny CPU wrapper na `simple_bus`**
* **firmware build**
* **ELF → BIN → HEX**
* **RAM init cez `$readmemh`**
* **jednoduchý LED program v C**

Toto je prvý moment, kde sa z frameworku stáva reálne použiteľný SoC flow.

---

# 1. Architektúrny cieľ

Po tomto kroku bude flow vyzerať takto:

```text
project.yaml
  ↓
SystemModel
  ↓
RTL emit
  ↓
soc_top.sv + cpu wrapper + ram + gpio shell
  ↓
firmware.elf
  ↓
firmware.bin
  ↓
firmware.hex
  ↓
soc_ram $readmemh(INIT_FILE)
```

---

# 2. PicoRV32 wrapper contract

PicoRV32 má natívne memory interface signály, nie `simple_bus`. Preto spravíme wrapper:

* vstup: `bus_if.master bus`
* vo vnútri:

  * PicoRV32 memory native port
  * preklad na `simple_bus`

Tento wrapper sa stane tým, čo CPU descriptor ukazuje ako `module`.

---

# 3. CPU descriptor

## `tests/golden/fixtures/picorv32_soc/ip/picorv32_min.cpu.yaml`

```yaml
version: 2
kind: cpu

cpu:
  name: picorv32_min
  module: picorv32_simple_bus_wrapper
  family: riscv32

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params:
  ENABLE_IRQ: true
  ENABLE_COUNTERS: false
  ENABLE_COUNTERS64: false
  TWO_STAGE_SHIFT: true
  BARREL_SHIFTER: false
  TWO_CYCLE_COMPARE: false
  TWO_CYCLE_ALU: false
  LATCHED_MEM_RDATA: false
  PROGADDR_RESET: 0x00000000
  PROGADDR_IRQ: 0x00000010
  STACKADDR: 0x00010000

artifacts:
  - tests/golden/fixtures/picorv32_soc/rtl/picorv32_simple_bus_wrapper.sv
  - tests/golden/fixtures/picorv32_soc/rtl/picorv32.v

notes:
  - PicoRV32 wrapped to simple_bus
```

---

# 4. PicoRV32 wrapper

## `tests/golden/fixtures/picorv32_soc/rtl/picorv32_simple_bus_wrapper.sv`

```systemverilog
`default_nettype none

module picorv32_simple_bus_wrapper #(
  parameter bit ENABLE_IRQ         = 1'b1,
  parameter bit ENABLE_COUNTERS    = 1'b0,
  parameter bit ENABLE_COUNTERS64  = 1'b0,
  parameter bit TWO_STAGE_SHIFT    = 1'b1,
  parameter bit BARREL_SHIFTER     = 1'b0,
  parameter bit TWO_CYCLE_COMPARE  = 1'b0,
  parameter bit TWO_CYCLE_ALU      = 1'b0,
  parameter bit LATCHED_MEM_RDATA  = 1'b0,
  parameter logic [31:0] PROGADDR_RESET = 32'h0000_0000,
  parameter logic [31:0] PROGADDR_IRQ   = 32'h0000_0010,
  parameter logic [31:0] STACKADDR      = 32'h0001_0000
)(
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] irq,
  bus_if.master      bus
);

  logic        mem_valid;
  logic        mem_instr;
  logic        mem_ready;
  logic [31:0] mem_addr;
  logic [31:0] mem_wdata;
  logic [3:0]  mem_wstrb;
  logic [31:0] mem_rdata;

  picorv32 #(
    .ENABLE_IRQ        (ENABLE_IRQ),
    .ENABLE_COUNTERS   (ENABLE_COUNTERS),
    .ENABLE_COUNTERS64 (ENABLE_COUNTERS64),
    .TWO_STAGE_SHIFT   (TWO_STAGE_SHIFT),
    .BARREL_SHIFTER    (BARREL_SHIFTER),
    .TWO_CYCLE_COMPARE (TWO_CYCLE_COMPARE),
    .TWO_CYCLE_ALU     (TWO_CYCLE_ALU),
    .LATCHED_MEM_RDATA (LATCHED_MEM_RDATA),
    .PROGADDR_RESET    (PROGADDR_RESET),
    .PROGADDR_IRQ      (PROGADDR_IRQ),
    .STACKADDR         (STACKADDR)
  ) u_cpu (
    .clk         (SYS_CLK),
    .resetn      (RESET_N),
    .trap        (),
    .mem_valid   (mem_valid),
    .mem_instr   (mem_instr),
    .mem_ready   (mem_ready),
    .mem_addr    (mem_addr),
    .mem_wdata   (mem_wdata),
    .mem_wstrb   (mem_wstrb),
    .mem_rdata   (mem_rdata),
    .irq         (irq),
    .eoi         (),
    .trace_valid (),
    .trace_data  (),
    .look_valid  (),
    .look_addr   (),
    .look_rdata  (),
    .look_wdata  (),
    .look_wstrb  ()
  );

  assign bus.addr  = mem_addr;
  assign bus.wdata = mem_wdata;
  assign bus.be    = (mem_wstrb == 4'b0000) ? 4'hF : mem_wstrb;
  assign bus.we    = |mem_wstrb;
  assign bus.valid = mem_valid;

  assign mem_ready = bus.ready;
  assign mem_rdata = bus.rdata;

endmodule

`default_nettype wire
```

---

# 5. RAM model s HEX init

RAM už máš, ale teraz ju spevníme pre firmware image flow.

## `tests/golden/fixtures/picorv32_soc/rtl/soc_ram.sv`

```systemverilog
`default_nettype none

module soc_ram #(
  parameter int RAM_BYTES = 65536,
  parameter string INIT_FILE = ""
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
);

  localparam int WORDS = RAM_BYTES / 4;
  logic [31:0] mem [0:WORDS-1];
  wire [31:2] word_addr = bus.addr[31:2];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1)
      mem[i] = 32'h00000013; // NOP for RISC-V

    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  always_ff @(posedge SYS_CLK) begin
    if (bus.valid && bus.we) begin
      if (bus.be[0]) mem[word_addr][7:0]   <= bus.wdata[7:0];
      if (bus.be[1]) mem[word_addr][15:8]  <= bus.wdata[15:8];
      if (bus.be[2]) mem[word_addr][23:16] <= bus.wdata[23:16];
      if (bus.be[3]) mem[word_addr][31:24] <= bus.wdata[31:24];
    end
  end

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = mem[word_addr];
  end

endmodule

`default_nettype wire
```

---

# 6. Firmware toolchain config v projekte

Rozšírime project YAML o firmware.

## update `socfw/config/project_schema.py`

Pridaj:

```python
class FirmwareSchema(BaseModel):
    enabled: bool = False
    src_dir: str | None = None
    out_dir: str = "build/fw"
    linker_script: str | None = None
    elf_file: str = "firmware.elf"
    bin_file: str = "firmware.bin"
    hex_file: str = "firmware.hex"
    tool_prefix: str = "riscv32-unknown-elf-"
    cflags: list[str] = Field(default_factory=list)
    ldflags: list[str] = Field(default_factory=list)
```

A do root:

```python
    firmware: FirmwareSchema | None = None
```

---

# 7. Firmware model

## nový `socfw/model/firmware.py`

```python
from __future__ import annotations
from dataclasses import dataclass, field


@dataclass
class FirmwareModel:
    enabled: bool = False
    src_dir: str | None = None
    out_dir: str = "build/fw"
    linker_script: str | None = None
    elf_file: str = "firmware.elf"
    bin_file: str = "firmware.bin"
    hex_file: str = "firmware.hex"
    tool_prefix: str = "riscv32-unknown-elf-"
    cflags: list[str] = field(default_factory=list)
    ldflags: list[str] = field(default_factory=list)
```

---

# 8. Project loader update

## `socfw/config/project_loader.py`

Import:

```python
from socfw.model.firmware import FirmwareModel
```

V `load()` vytvor:

```python
        firmware = None
        if doc.firmware is not None:
            firmware = FirmwareModel(
                enabled=doc.firmware.enabled,
                src_dir=doc.firmware.src_dir,
                out_dir=doc.firmware.out_dir,
                linker_script=doc.firmware.linker_script,
                elf_file=doc.firmware.elf_file,
                bin_file=doc.firmware.bin_file,
                hex_file=doc.firmware.hex_file,
                tool_prefix=doc.firmware.tool_prefix,
                cflags=list(doc.firmware.cflags),
                ldflags=list(doc.firmware.ldflags),
            )
```

A return bundle rozšír:

```python
            "firmware": firmware,
```

---

# 9. System model update

## `socfw/model/system.py`

Pridaj:

```python
from .firmware import FirmwareModel
```

A do `SystemModel`:

```python
    firmware: FirmwareModel | None = None
```

---

## `socfw/config/system_loader.py`

Pri bundle unpack:

```python
        firmware = prj_bundle["firmware"]
```

A do `SystemModel(...)`:

```python
            firmware=firmware,
```

---

# 10. Firmware build model

## nový `socfw/model/image.py`

```python
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class FirmwareArtifacts:
    elf: str
    bin: str
    hex: str
```

---

# 11. Firmware builder

## nový `socfw/tools/firmware_builder.py`

```python
from __future__ import annotations

import subprocess
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result
from socfw.model.image import FirmwareArtifacts


class FirmwareBuilder:
    def build(self, system, out_dir: str) -> Result[FirmwareArtifacts]:
        if system.firmware is None or not system.firmware.enabled:
            return Result()

        fw = system.firmware
        if fw.src_dir is None:
            return Result(diagnostics=[
                Diagnostic(
                    code="FW001",
                    severity=Severity.ERROR,
                    message="firmware.enabled=true but firmware.src_dir is missing",
                    subject="project.firmware",
                )
            ])

        outp = Path(out_dir) / "fw"
        outp.mkdir(parents=True, exist_ok=True)

        elf = str(outp / fw.elf_file)
        binf = str(outp / fw.bin_file)
        hexf = str(outp / fw.hex_file)

        cc = f"{fw.tool_prefix}gcc"
        objcopy = f"{fw.tool_prefix}objcopy"

        c_sources = sorted(str(p) for p in Path(fw.src_dir).glob("*.c"))
        if not c_sources:
            return Result(diagnostics=[
                Diagnostic(
                    code="FW002",
                    severity=Severity.ERROR,
                    message=f"No C sources found in firmware.src_dir={fw.src_dir}",
                    subject="project.firmware",
                )
            ])

        cmd_compile = [
            cc,
            "-Os",
            "-march=rv32im",
            "-mabi=ilp32",
            "-ffreestanding",
            "-nostdlib",
            "-Wl,-Bstatic",
            "-Wl,--strip-debug",
            "-o", elf,
            *c_sources,
        ]

        if fw.linker_script:
            cmd_compile.extend(["-T", fw.linker_script])

        cmd_compile.extend(fw.cflags)
        cmd_compile.extend(fw.ldflags)

        try:
            subprocess.run(cmd_compile, check=True)
            subprocess.run([objcopy, "-O", "binary", elf, binf], check=True)
        except FileNotFoundError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="FW003",
                    severity=Severity.ERROR,
                    message=f"Firmware tool not found: {exc}",
                    subject="project.firmware",
                )
            ])
        except subprocess.CalledProcessError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="FW004",
                    severity=Severity.ERROR,
                    message=f"Firmware build failed: {exc}",
                    subject="project.firmware",
                )
            ])

        return Result(value=FirmwareArtifacts(elf=elf, bin=binf, hex=hexf))
```

---

# 12. BIN → HEX conversion

Toto nadviaže na skorší runner.

## nový `socfw/tools/bin2hex_runner.py`

```python
from __future__ import annotations

import subprocess
import sys

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result


class Bin2HexRunner:
    def __init__(self, tool_path: str = "bin2hex.py") -> None:
        self.tool_path = tool_path

    def run(self, bin_file: str, hex_file: str, size_bytes: int) -> Result[str]:
        cmd = [
            sys.executable,
            self.tool_path,
            bin_file,
            hex_file,
            hex(size_bytes),
        ]

        try:
            subprocess.run(cmd, check=True)
        except FileNotFoundError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="IMG001",
                    severity=Severity.ERROR,
                    message=f"bin2hex tool not found: {exc}",
                    subject="firmware.image",
                )
            ])
        except subprocess.CalledProcessError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="IMG002",
                    severity=Severity.ERROR,
                    message=f"bin2hex failed: {exc}",
                    subject="firmware.image",
                )
            ])

        return Result(value=hex_file)
```

---

# 13. Prepojenie firmware.hex do RAM

Najčistejšie: ak sa firmware postaví úspešne, prepíš `system.ram.init_file`.

## `socfw/build/full_pipeline.py`

Pridaj importy:

```python
from socfw.tools.bin2hex_runner import Bin2HexRunner
from socfw.tools.firmware_builder import FirmwareBuilder
```

V `__init__`:

```python
        self.firmware_builder = FirmwareBuilder()
        self.bin2hex = Bin2HexRunner()
```

V `run()` hneď po `system = loaded.value` a pred `pipeline.run(...)`:

```python
        fw_res = self.firmware_builder.build(system, request.out_dir)
        loaded.diagnostics.extend(fw_res.diagnostics)

        if fw_res.ok and fw_res.value is not None and system.ram is not None:
            conv = self.bin2hex.run(
                fw_res.value.bin,
                fw_res.value.hex,
                system.ram.size,
            )
            loaded.diagnostics.extend(conv.diagnostics)
            if conv.ok and conv.value is not None:
                system.ram = type(system.ram)(
                    module=system.ram.module,
                    base=system.ram.base,
                    size=system.ram.size,
                    data_width=system.ram.data_width,
                    addr_width=system.ram.addr_width,
                    latency=system.ram.latency,
                    init_file=conv.value,
                    image_format="hex",
                )
```

Tým pádom sa do RTL buildera dostane už aktualizovaný `INIT_FILE`.

---

# 14. Firmware fixture

## `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include "soc_map.h"

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    while (1) {
        GPIO0_VALUE_REG = 0x15;
        delay(200000);

        GPIO0_VALUE_REG = 0x2A;
        delay(200000);
    }

    return 0;
}
```

---

# 15. Project fixture

## `tests/golden/fixtures/picorv32_soc/project.yaml`

```yaml
version: 2
kind: project

project:
  name: picorv32_soc
  mode: soc
  board: qmtech_ep4ce55
  board_file: tests/golden/fixtures/picorv32_soc/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - tests/golden/fixtures/picorv32_soc/ip

features:
  use:
    - board:onboard.leds

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
  generated: []

cpu:
  instance: cpu0
  type: picorv32_min
  fabric: main
  reset_vector: 0x00000000
  params:
    ENABLE_IRQ: true
    PROGADDR_RESET: 0x00000000
    STACKADDR: 0x00010000

ram:
  module: soc_ram
  base: 0x00000000
  size: 65536
  latency: registered
  init_file: ""
  image_format: hex

boot:
  reset_vector: 0x00000000
  stack_percent: 25

buses:
  - name: main
    protocol: simple_bus
    addr_width: 32
    data_width: 32

firmware:
  enabled: true
  src_dir: tests/golden/fixtures/picorv32_soc/fw
  out_dir: build/fw
  linker_script: build/gen/sw/sections.lds
  elf_file: firmware.elf
  bin_file: firmware.bin
  hex_file: firmware.hex
  tool_prefix: riscv32-unknown-elf-
  cflags:
    - -Ibuild/gen/sw

modules:
  - instance: gpio0
    type: gpio
    bus:
      fabric: main
      base: 0x40000000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        gpio_o:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, software, docs]
```

---

# 16. Jedna dôležitá praktická poznámka

Tento linker script sa v projekte generuje počas buildu, ale firmware sa buildí pred RTL emitom. Preto sú tu dve možnosti:

## jednoduchšia prvá verzia

Firmware build robiť **po prvom emite software artefaktov**.

To je v praxi lepšie.

---

## upravený poriadok v `FullBuildPipeline.run()`

Odporúčam takto:

1. load system
2. pipeline.run(system) → získaš `software_ir`
3. emit software/docs/board/rtl
4. build firmware
5. bin2hex
6. ak vznikol nový hex, spraviť druhý krát len `rtl` emit alebo nastaviť RAM `INIT_FILE` už pred prvým emitom cez `software_ir`

Najčistejšie minimum je:

* prvý run bez firmware hex
* vyemituj `sections.lds` a `soc_map.h`
* build firmware
* convert to hex
* druhý run s `system.ram.init_file = firmware.hex`

To je dvojfázový build.

---

# 17. Odporúčaný dvojfázový build

## `socfw/build/full_pipeline.py`

Odporúčaný flow:

```python
# pass 1
result = self.pipeline.run(request, system)
emit software/docs/board/rtl

# build firmware now that linker/header exist
fw_res = self.firmware_builder.build(system, request.out_dir)
bin2hex ...

# patch ram init file
# pass 2
result = self.pipeline.run(request, system_with_hex)
emit again
```

Je to čisté a spoľahlivé.

---

# 18. Čo týmto získaš

Po tomto kroku už framework vie:

* CPU z descriptoru
* reálny softcore wrapper
* reálny firmware build
* reálny RAM init
* LED blink z C programu

Toto je prvý naozaj presvedčivý end-to-end SoC demo slice.

---

# 19. Čo by som spravil hneď potom

Teraz sú dve prirodzené vetvy:

### A

**PicoRV32 wrapper spevnenie**

* valid/ready wait states
* byte access edge cases
* IRQ handling demo
* trap/debug mapping

### B

**bus adapter architektúra**

* AXI-lite peripheral bridge
* Wishbone bridge
* protocol plugin registry

Môj praktický odporúčaný ďalší krok je:

👉 **A — PicoRV32 wrapper spevnenie + dvojfázový build cleanup**

Lebo tým získaš prvý spoľahlivý živý SoC, na ktorom sa dá ďalej stavať.

Ak chceš, ďalšia správa môže byť presne:
**dvojfázový build flow + PicoRV32 wrapper robustness + prvý integration test pre firmware blink**
