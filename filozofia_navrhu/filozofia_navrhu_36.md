Perfektné. Ideme na:

# IRQ demo firmware + smoke simulation harness + wrapper cleanup checklist

Toto je presne ten krok, ktorý z “framework vie vygenerovať RTL a firmware” posunie projekt na:

* **framework viem rýchlo overiť**
* **mám minimálnu simuláciu**
* **mám IRQ end-to-end demo**
* **viem, čo spevniť na CPU wrapperi pred ďalším rastom**

Rozdelím to na 3 časti:

1. **IRQ demo firmware**
2. **smoke simulation harness**
3. **wrapper cleanup checklist**

---

# 1. IRQ demo firmware

Cieľ:

* GPIO zmení `irq_pending`
* CPU firmware prečíta pending bit
* firmware ho clearne cez `clear_on_write`
* LED pattern sa zmení podľa toho, či IRQ prišlo

Keďže ešte nemáme plný machine-mode interrupt handler stack, spravíme to pragmaticky:

* firmware bude **pollovať** IRQ pending register
* ale infraštruktúra bude už pripravená na skutočné IRQ neskôr

To je veľmi dobrý medzikrok.

---

## `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include "soc_map.h"

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    unsigned value = 0x01;

    while (1) {
        GPIO0_VALUE_REG = value;
        delay(150000);

        if (GPIO0_IRQ_PENDING_REG & 0x1) {
            /* acknowledge sticky pending bit */
            GPIO0_IRQ_PENDING_REG = 0x1;

            /* visible pattern change after event */
            value ^= 0x3F;
        } else {
            value = ((value << 1) & 0x3F);
            if (value == 0)
                value = 0x01;
        }

        delay(150000);
    }

    return 0;
}
```

Toto má dve výhody:

* okamžite testuje register mapu aj C header
* hneď testuje `clear_on_write` správanie

---

## `tests/golden/fixtures/picorv32_soc/fw/start.S`

Zostáva jednoduché:

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

# 2. Voliteľný minimalistický IRQ handler groundwork

Ak chceš pripraviť firmware aj na neskorší “real IRQ path”, môžeš si už teraz doplniť symboly a rezervy.

## `tests/golden/fixtures/picorv32_soc/fw/irq.c`

```c
#include <stdint.h>

volatile uint32_t g_irq_count = 0;

void irq_entry(void) {
    g_irq_count++;
}
```

Toto ešte nemusí byť skutočne napojené, ale vytvorí základ pre ďalší krok, keď spravíš reálny interrupt dispatch.

---

# 3. Smoke simulation harness

Toto je obrovsky užitočné. Chceš mať:

* rýchly test, že top sa aspoň rozbehne,
* nemusíš hneď robiť plný Quartus flow,
* môžeš kontrolovať RAM init a LED signály.

Najjednoduchší prvý krok je plain Verilog testbench.

---

## `tests/golden/fixtures/picorv32_soc/tb/tb_soc_top.sv`

```systemverilog
`timescale 1ns/1ps
`default_nettype none

module tb_soc_top;

  logic SYS_CLK;
  logic RESET_N;
  wire [5:0] ONB_LEDS;

  soc_top dut (
    .SYS_CLK (SYS_CLK),
    .RESET_N (RESET_N),
    .ONB_LEDS(ONB_LEDS)
  );

  initial begin
    SYS_CLK = 1'b0;
    forever #10 SYS_CLK = ~SYS_CLK; // 50 MHz
  end

  initial begin
    RESET_N = 1'b0;
    repeat (10) @(posedge SYS_CLK);
    RESET_N = 1'b1;
  end

  initial begin
    $display("[TB] starting simulation");
    repeat (5000) @(posedge SYS_CLK);

    $display("[TB] LED state = %b", ONB_LEDS);

    if (^ONB_LEDS === 1'bx) begin
      $fatal(1, "[TB] LED state contains X");
    end

    $finish;
  end

endmodule

`default_nettype wire
```

Tento TB je zámerne jednoduchý:

* overí reset
* nechá CPU trochu bežať
* skontroluje, že LED nie je `X`

---

# 4. Simulation manifest emitter

Aby si simuláciu vedel spúšťať jednotne, oplatí sa generovať jednoduchý filelist.

## nový `socfw/emit/sim_filelist_emitter.py`

```python
from __future__ import annotations

from pathlib import Path

from socfw.build.manifest import GeneratedArtifact


class SimFilelistEmitter:
    def emit(self, ctx, ir) -> list[GeneratedArtifact]:
        out = Path(ctx.out_dir) / "sim" / "files.f"
        out.parent.mkdir(parents=True, exist_ok=True)

        lines: list[str] = []
        lines.append("rtl/soc_top.sv")

        for fp in sorted(ir.extra_sources):
            lines.append(fp)

        tb = Path(ctx.out_dir) / "sim" / "tb_soc_top.sv"
        if tb.exists():
            lines.append(str(tb))

        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return [GeneratedArtifact("sim", str(out), self.__class__.__name__)]
```

---

## `socfw/plugins/bootstrap.py`

Pridaj:

```python
from socfw.emit.sim_filelist_emitter import SimFilelistEmitter
```

a registráciu:

```python
    reg.register_emitter("sim", SimFilelistEmitter())
```

---

## `socfw/emit/orchestrator.py`

Doplň ordered:

```python
        ordered = [
            ("board", board_ir),
            ("rtl", rtl_ir),
            ("timing", timing_ir),
            ("files", rtl_ir),
            ("software", software_ir),
            ("docs", docs_ir),
            ("sim", rtl_ir),
        ]
```

---

# 5. Copy TB helper

Aby sa TB dostal do output directory, sprav jednoduchý helper emitter alebo utilitu. Najmenšia cesta je utilita.

## nový `socfw/tools/testbench_stager.py`

```python
from __future__ import annotations

import shutil
from pathlib import Path


class TestbenchStager:
    def stage(self, project_file: str, out_dir: str) -> None:
        project_path = Path(project_file)
        tb_dir = project_path.parent / "tb"
        if not tb_dir.exists():
            return

        out_tb_dir = Path(out_dir) / "sim"
        out_tb_dir.mkdir(parents=True, exist_ok=True)

        for tb in tb_dir.glob("*.sv"):
            shutil.copy2(tb, out_tb_dir / tb.name)
```

---

## `socfw/build/two_pass_flow.py`

Pridaj import:

```python
from socfw.tools.testbench_stager import TestbenchStager
```

V `__init__`:

```python
        self.tb_stager = TestbenchStager()
```

Na začiatok `run()`:

```python
        self.tb_stager.stage(request.project_file, request.out_dir)
```

Tým pádom sa `tb_soc_top.sv` objaví v `build/.../sim`.

---

# 6. Jednoduchý sim runner

Ak chceš lokálne veľmi rýchly smoke test, priprav wrapper na `iverilog`.

## nový `socfw/tools/sim_runner.py`

```python
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.core.result import Result


class SimRunner:
    def run_iverilog(self, out_dir: str, top: str = "tb_soc_top") -> Result[str]:
        if shutil.which("iverilog") is None:
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM001",
                    severity=Severity.WARNING,
                    message="iverilog not found, skipping simulation",
                    subject="simulation",
                )
            ])

        sim_dir = Path(out_dir) / "sim"
        filelist = sim_dir / "files.f"
        vvp_file = sim_dir / "sim.vvp"

        cmd_compile = [
            "iverilog",
            "-g2012",
            "-s", top,
            "-o", str(vvp_file),
            "-f", str(filelist),
        ]

        try:
            subprocess.run(cmd_compile, check=True, cwd=out_dir)
            subprocess.run(["vvp", str(vvp_file)], check=True, cwd=out_dir)
        except subprocess.CalledProcessError as exc:
            return Result(diagnostics=[
                Diagnostic(
                    code="SIM002",
                    severity=Severity.ERROR,
                    message=f"Simulation failed: {exc}",
                    subject="simulation",
                )
            ])

        return Result(value=str(vvp_file))
```

---

# 7. CLI príkaz `sim-smoke`

## `socfw/cli/main.py`

Pridaj import:

```python
from socfw.build.two_pass_flow import TwoPassBuildFlow
from socfw.tools.sim_runner import SimRunner
```

Pridaj handler:

```python
def cmd_sim_smoke(args) -> int:
    flow = TwoPassBuildFlow(templates_dir=args.templates)
    result = flow.run(BuildRequest(project_file=args.project, out_dir=args.out))

    for d in result.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    if not result.ok:
        return 1

    sim = SimRunner().run_iverilog(args.out)
    for d in sim.diagnostics:
        print(f"{d.severity.value.upper()} {d.code}: {d.message}")

    return 0 if sim.ok else 1
```

A do parsera:

```python
    s = sub.add_parser("sim-smoke")
    s.add_argument("project")
    s.add_argument("--out", default="build/gen")
    s.add_argument("--templates", default=_default_templates_dir())
    s.set_defaults(func=cmd_sim_smoke)
```

---

# 8. Integration test pre smoke sim

## `tests/integration/test_sim_picorv32_smoke.py`

```python
import shutil
import pytest
from pathlib import Path

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow
from socfw.tools.sim_runner import SimRunner


@pytest.mark.skipif(
    shutil.which("iverilog") is None,
    reason="iverilog not installed",
)
def test_sim_picorv32_smoke(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    sim = SimRunner().run_iverilog(str(out_dir))
    assert sim.ok
    assert (out_dir / "sim" / "files.f").exists()
```

---

# 9. Wrapper cleanup checklist

Toto je checklist, ktorý by som si dal do `docs/dev_notes/picorv32_wrapper_checklist.md`.

# PicoRV32 wrapper cleanup checklist

## Hotové

* basic simple_bus adapter
* request hold until ready
* irq port connected
* reset/clock descriptor-driven
* firmware boots from RAM hex

## Ešte spevniť

* confirm mem_valid/mem_ready handshake against PicoRV32 timing expectations
* verify back-to-back requests with wait-state slaves
* verify byte write semantics on RAM and GPIO
* decide misaligned access policy
* define behavior for unmapped address
* add optional timeout/error slave
* add trap visibility to report/sim logs
* expose mem_instr in graph/report/debug if useful

## Sim smoke cases

* LED register write from firmware
* IRQ pending set + clear_on_write
* RAM read after write
* wait-state insertion on one slave
* unmapped access behavior

---

# 10. Ďalší veľmi užitočný krok: error slave

Momentálne ak CPU trafí nepokrytú adresu, fabric môže držať nuly alebo nejasné správanie. Ďalší malý krok by mal doplniť:

* `simple_bus_error_slave`
* alebo default response vo fabric

Napríklad:

* `ready=1`
* `rdata=32'hDEADBEEF`

To veľmi pomáha pri debugovaní.

---

# 11. Čo týmto získaš

Po tomto kroku už máš:

* descriptor-driven CPU
* dvojfázový firmware-aware build
* HEX init do RAM
* smoke simulation
* IRQ demo firmware
* rýchly základ pre regression testy

To je už veľmi silný interný milestone.

---

# 12. Čo by som spravil hneď potom

Najlepší ďalší krok teraz je:

### možnosť A

**error slave + wait-state test peripheral + mapped/unmapped behavior**

### možnosť B

**AXI-lite peripheral bridge**, aby si ukázal rozšíriteľnosť frameworku

Môj praktický odporúčaný ďalší krok je:

👉 **A — error slave + wait-state simulation + robustness of simple_bus fabric**

Lebo tým spevníš základný bus contract ešte pred tým, než začneš pridávať nové protokoly.

Ak chceš, ďalšia správa môže byť presne:
**error slave + wait-state slave + fabric robustness slice**
