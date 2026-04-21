Super. Ideme na:

# dvojfázový build flow + PicoRV32 wrapper robustness + prvý integration test pre firmware blink

Toto je presne krok, ktorý spraví z doterajšieho návrhu niečo výrazne stabilnejšie.

Cieľ:

* mať **deterministický dvojfázový build**
* mať **PicoRV32 wrapper**, ktorý zvláda wait-state handshake korektnejšie
* mať **integračný test**, ktorý overí:

  * firmware build,
  * HEX image,
  * vygenerovaný top,
  * linker/header flow

Tým sa uzavrie prvý naozaj použiteľný vertikálny slice.

---

# 1. Problém, ktorý teraz riešime

Doteraz je flow približne:

1. načítaj config
2. buildni RTL/SW
3. buildni firmware
4. urob hex
5. RAM potrebuje `INIT_FILE`

To znamená, že firmware vzniká až po tom, čo sa generujú SW artefakty, ale zároveň RAM ho chce poznať už pri emite RTL.

To je ideálny prípad na **dvojfázový build**.

---

# 2. Cieľový dvojfázový flow

Správny flow:

## Pass 1

* load config
* validate
* elaborate
* vygeneruj:

  * `soc_map.h`
  * `sections.lds`
  * `docs`
  * `board.tcl`
  * `files.tcl`
  * `soc_top.sv` bez finálneho HEX alebo s prázdnym `INIT_FILE`

## Firmware step

* build firmware z C
* `ELF -> BIN`
* `BIN -> HEX`

## Pass 2

* patchni `system.ram.init_file`
* znovu spusti pipeline
* znovu emitni RTL/files/report

Výsledok:

* linker script aj header sú pripravené včas
* RAM dostane reálny HEX
* výsledný top je konzistentný

---

# 3. Stabilný wrapper pre PicoRV32

Doteraz wrapper mapuje `mem_valid` priamo na `bus.valid`, čo je minimum. Lepšie je mať malý request register, aby sa korektne držal request do `ready`.

To je bezpečnejšie pri wait-state slave.

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

  logic        req_active;
  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_wstrb;

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

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      req_active <= 1'b0;
      req_addr   <= 32'h0;
      req_wdata  <= 32'h0;
      req_wstrb  <= 4'h0;
    end else begin
      if (!req_active && mem_valid) begin
        req_active <= 1'b1;
        req_addr   <= mem_addr;
        req_wdata  <= mem_wdata;
        req_wstrb  <= mem_wstrb;
      end else if (req_active && bus.ready) begin
        req_active <= 1'b0;
      end
    end
  end

  assign bus.addr  = req_active ? req_addr  : mem_addr;
  assign bus.wdata = req_active ? req_wdata : mem_wdata;
  assign bus.be    = ((req_active ? req_wstrb : mem_wstrb) == 4'b0000) ? 4'hF : (req_active ? req_wstrb : mem_wstrb);
  assign bus.we    = |(req_active ? req_wstrb : mem_wstrb);
  assign bus.valid = req_active | mem_valid;

  assign mem_ready = bus.ready;
  assign mem_rdata = bus.rdata;

endmodule

`default_nettype wire
```

Tento wrapper nie je ešte plnohodnotný bus adapter so všetkými corner cases, ale je výrazne robustnejší než priamy combinational pass-through.

---

# 4. Dvojfázový build runner

Najčistejšie je spraviť samostatný orchestrátor pre firmware-aware build.

## nový `socfw/build/two_pass_flow.py`

```python
from __future__ import annotations

from dataclasses import replace

from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline
from socfw.core.diagnostics import Diagnostic, Severity
from socfw.tools.bin2hex_runner import Bin2HexRunner
from socfw.tools.firmware_builder import FirmwareBuilder


class TwoPassBuildFlow:
    def __init__(self, templates_dir: str) -> None:
        self.pipeline = FullBuildPipeline(templates_dir=templates_dir)
        self.firmware_builder = FirmwareBuilder()
        self.bin2hex = Bin2HexRunner()

    def run(self, request: BuildRequest):
        # pass 1: generate headers/linker/docs/top without final RAM init
        first = self.pipeline.run(request)
        if not first.ok:
            return first

        # reload system again through pipeline loader to get fresh mutable model
        loaded = self.pipeline.loader.load(request.project_file)
        if not loaded.ok or loaded.value is None:
            first.diagnostics.extend(loaded.diagnostics)
            first.ok = False
            return first

        system = loaded.value

        if system.firmware is None or not system.firmware.enabled or system.ram is None:
            return first

        fw_res = self.firmware_builder.build(system, request.out_dir)
        first.diagnostics.extend(fw_res.diagnostics)
        if not fw_res.ok or fw_res.value is None:
            first.ok = False
            return first

        conv = self.bin2hex.run(
            fw_res.value.bin,
            fw_res.value.hex,
            system.ram.size,
        )
        first.diagnostics.extend(conv.diagnostics)
        if not conv.ok or conv.value is None:
            first.ok = False
            return first

        # patch RAM init and rerun full pipeline
        system.ram = replace(system.ram, init_file=conv.value, image_format="hex")

        second = self.pipeline.pipeline.run(request, system)
        second.diagnostics = loaded.diagnostics + second.diagnostics + first.diagnostics

        if not second.ok:
            return second

        ctx = self.pipeline.emitters
        # reuse normal emit/report path from FullBuildPipeline pieces
        build_ctx = self.pipeline.pipeline  # not used directly, just for symmetry

        from pathlib import Path
        from socfw.build.context import BuildContext

        out_ctx = BuildContext(out_dir=Path(request.out_dir))
        second.manifest = self.pipeline.emitters.emit_all(
            out_ctx,
            board_ir=second.board_ir,
            timing_ir=second.timing_ir,
            rtl_ir=second.rtl_ir,
            software_ir=second.software_ir,
            docs_ir=second.docs_ir,
            register_block_irs=second.register_block_irs,
            peripheral_shell_irs=second.peripheral_shell_irs,
        )

        report_paths = self.pipeline.reports.emit_all(
            system=system,
            design=second.design,
            result=second,
            out_dir=request.out_dir,
        )
        for p in report_paths:
            second.manifest.add("report", p, "ReportOrchestrator")

        # surface firmware artifacts in manifest
        second.manifest.add("firmware", fw_res.value.elf, "FirmwareBuilder")
        second.manifest.add("firmware", fw_res.value.bin, "FirmwareBuilder")
        second.manifest.add("firmware", fw_res.value.hex, "Bin2HexRunner")

        return second
```

---

# 5. Menší cleanup: `BuildResult`

Aby dvojfázový flow fungoval čisto, `BuildResult` nech nesie aj shell/regblock IR, ak si ich už doplnil skôr.

## update `socfw/build/pipeline.py`

Do `BuildResult`:

```python
    software_ir: object | None = None
    register_block_irs: list[object] = field(default_factory=list)
    peripheral_shell_irs: list[object] = field(default_factory=list)
```

Ak to už tam máš, netreba meniť.

---

# 6. CLI: nový príkaz `build-fw`

Najpraktickejšie je nepreťažovať `build`, ale pridať samostatný command.

## update `socfw/cli/main.py`

Pridaj import:

```python
from socfw.build.two_pass_flow import TwoPassBuildFlow
```

Pridaj command handler:

```python
def cmd_build_fw(args) -> int:
    flow = TwoPassBuildFlow(templates_dir=args.templates)
    result = flow.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if result.ok:
        for art in result.manifest.artifacts:
            print(f"[{art.family}] {art.path}")

    return 0 if result.ok else 1
```

A do parsera:

```python
    bf = sub.add_parser("build-fw")
    bf.add_argument("project")
    bf.add_argument("--out", default="build/gen")
    bf.add_argument("--templates", default=_default_templates_dir())
    bf.set_defaults(func=cmd_build_fw)
```

---

# 7. Firmware builder robustness

Tvoj súčasný `FirmwareBuilder` predpokladá len `*.c`. Lepšie je dovoliť aj `*.S`.

## update `socfw/tools/firmware_builder.py`

Nahraď source discovery:

```python
        c_sources = sorted(str(p) for p in Path(fw.src_dir).glob("*.c"))
        asm_sources = sorted(str(p) for p in Path(fw.src_dir).glob("*.S"))
        sources = c_sources + asm_sources
        if not sources:
            return Result(diagnostics=[
                Diagnostic(
                    code="FW002",
                    severity=Severity.ERROR,
                    message=f"No firmware sources found in firmware.src_dir={fw.src_dir}",
                    subject="project.firmware",
                )
            ])
```

A v compile cmd:

```python
            *sources,
```

---

# 8. Startup stub

Aby bol firmware build realistickejší, pridaj jednoduchý `_start`.

## `tests/golden/fixtures/picorv32_soc/fw/start.S`

```asm
.section .text.start
.global _start
_start:
  la sp, _stack_top
  call main
1:
  j 1b
```

---

# 9. Firmware integration test

Toto je prvý skutočný end-to-end test, ktorý overí celý flow.

## `tests/integration/test_build_picorv32_fw.py`

```python
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


def test_build_picorv32_fw(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    # This test assumes riscv toolchain is installed in CI/dev env.
    assert result.ok

    assert (out_dir / "fw" / "firmware.elf").exists()
    assert (out_dir / "fw" / "firmware.bin").exists()
    assert (out_dir / "fw" / "firmware.hex").exists()

    rtl_top = out_dir / "rtl" / "soc_top.sv"
    assert rtl_top.exists()
    text = rtl_top.read_text(encoding="utf-8")
    assert "picorv32_simple_bus_wrapper" in text
    assert "INIT_FILE" in text

    soc_map = out_dir / "sw" / "soc_map.h"
    assert soc_map.exists()
    assert "GPIO0_VALUE_REG" in soc_map.read_text(encoding="utf-8")
```

---

# 10. Toolchain-aware skip

Ak nechceš, aby test padal tam, kde nie je toolchain, daj skip guard.

## lepšia verzia testu

```python
import shutil
import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow


@pytest.mark.skipif(
    shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="RISC-V toolchain not installed",
)
def test_build_picorv32_fw(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    assert (out_dir / "fw" / "firmware.elf").exists()
    assert (out_dir / "fw" / "firmware.bin").exists()
    assert (out_dir / "fw" / "firmware.hex").exists()
    assert (out_dir / "rtl" / "soc_top.sv").exists()
    assert (out_dir / "sw" / "soc_map.h").exists()
```

---

# 11. Report rozšírenie o firmware artefakty

Toto už čiastočne vyrieši manifest, ale je dobré ich vidieť aj v reportoch. Keďže ich pridávaš do manifestu ako `family="firmware"`, automaticky sa objavia v `build_report.md/json`. To je fajn bez ďalšieho zásahu.

---

# 12. Prvé praktické príkazy

Keď bude tento slice hotový, budeš vedieť spustiť:

```bash
socfw build-fw tests/golden/fixtures/picorv32_soc/project.yaml --out build/picorv32_soc
```

A očakávať:

* `build/picorv32_soc/fw/firmware.elf`
* `build/picorv32_soc/fw/firmware.bin`
* `build/picorv32_soc/fw/firmware.hex`
* `build/picorv32_soc/rtl/soc_top.sv`
* `build/picorv32_soc/sw/soc_map.h`
* `build/picorv32_soc/sw/sections.lds`
* `build/picorv32_soc/reports/build_report.json`
* `build/picorv32_soc/reports/build_report.md`
* `build/picorv32_soc/reports/soc_graph.dot`

---

# 13. Čo je po tomto už fakt silné

Po tomto kroku už framework vie:

* descriptor-driven CPU
* real softcore wrapper
* generated SW headers/docs
* generated linker script
* firmware compile
* bin→hex image
* RAM init
* generated peripheral control plane

To je už veľmi presvedčivý základ.

---

# 14. Čo by som spravil hneď potom

Teraz sú najlepšie dva smery:

### A

**PicoRV32 wrapper a memory-map robustness**

* presnejší handshake
* misaligned access policy
* trap/debug
* IRQ demo firmware

### B

**bus adapter architektúra**

* AXI-lite peripheral wrapper
* Wishbone bridge
* protocol plugin registry

Môj praktický odporúčaný ďalší krok je:

👉 **A — PicoRV32 wrapper robustness + IRQ demo firmware + smoke simulation harness**

Lebo tým dostaneš prvý skutočne “živý” a dôveryhodný SoC demo flow.

Ak chceš, ďalšia správa môže byť presne:
**IRQ demo firmware + smoke simulation harness + wrapper cleanup checklist**
