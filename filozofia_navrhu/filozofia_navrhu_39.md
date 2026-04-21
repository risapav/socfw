Super. Ideme na:

# PicoRV32 real IRQ entry + ASM startup + minimal ISR framework + firmware example

Toto je krok, kde sa SoC posunie z:

* **polling-based interrupt demo**

na:

* **skutočný interrupt-driven firmware flow**

Cieľ:

* mať reálny IRQ entry bod
* mať minimálny startup/runtime model
* mať jednoduchý ISR dispatch
* mať firmware, ktoré:

  * povolí IRQ
  * dostane interrupt
  * ackne source v IRQ controllery
  * zmení správanie LED

Nebudem tu predstierať úplnú ABI dokonalosť pre všetky varianty PicoRV32 konfigurácie. Dám ti **praktický minimálny slice**, ktorý je dobrý základ a dá sa ďalej spevniť.

---

# 1. Dôležité rozhodnutie

Pre prvý reálny IRQ path odporúčam:

* držať sa **jedného jednoduchého IRQ dispatch modelu**
* nepridávať ešte plnú všeobecnú runtime knižnicu
* urobiť:

  * `_start`
  * init stack
  * init vector/IRQ path
  * jednoduchý `irq_handler()`

Teda nie RTOS, nie plný BSP, ale malý bring-up runtime.

---

# 2. Predpoklad wrappera a CPU konfigurácie

Aby IRQ fungovalo rozumne, CPU descriptor nech má:

* `ENABLE_IRQ = true`
* `PROGADDR_IRQ = 0x00000010`

A firmware linker nech uloží IRQ entry na adresu `0x10`.

To znamená:

* reset vector: `0x00000000`
* IRQ entry: `0x00000010`

To je jednoduché a pre bring-up ideálne.

---

# 3. Linker script update

Potrebujeme vedieť umiestniť `.text.irq` na správne miesto.

## update `socfw/templates/sections.lds.j2`

Nahraď obsah za:

```jinja2
/* AUTO-GENERATED - DO NOT EDIT */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  RAM (rwx) : ORIGIN = 0x{{ "%08X"|format(sw.ram_base) }}, LENGTH = {{ sw.ram_size }}
}

SECTIONS {
  . = ORIGIN(RAM);

  .text.reset : {
    KEEP(*(.text.start))
  } > RAM

  . = ORIGIN(RAM) + 0x10;

  .text.irq : {
    KEEP(*(.text.irq))
  } > RAM

  . = ALIGN(4);

  .text : {
    *(.text*)
    *(.rodata*)
  } > RAM

  .data : {
    *(.data*)
  } > RAM

  .bss : {
    __bss_start = .;
    *(.bss*) *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  _stack_top  = ORIGIN(RAM) + LENGTH(RAM);
  _stack_size = LENGTH(RAM) * {{ sw.stack_percent }} / 100;
  _stack_base = _stack_top - _stack_size;
}
```

Týmto dostaneš:

* `_start` na začiatku RAM
* IRQ entry na `0x10`

---

# 4. Startup ASM

Teraz treba mať:

* `_start`
* stack init
* skok do `main`
* IRQ entry stub na `0x10`

## `tests/golden/fixtures/picorv32_soc/fw/start.S`

```asm
.section .text.start
.global _start
_start:
  la sp, _stack_top
  call main
1:
  j 1b

.section .text.irq
.global irq_entry
irq_entry:
  addi sp, sp, -64
  sw ra,  0(sp)
  sw t0,  4(sp)
  sw t1,  8(sp)
  sw t2, 12(sp)
  sw a0, 16(sp)
  sw a1, 20(sp)
  sw a2, 24(sp)
  sw a3, 28(sp)
  sw a4, 32(sp)
  sw a5, 36(sp)
  sw a6, 40(sp)
  sw a7, 44(sp)

  call irq_handler

  lw ra,  0(sp)
  lw t0,  4(sp)
  lw t1,  8(sp)
  lw t2, 12(sp)
  lw a0, 16(sp)
  lw a1, 20(sp)
  lw a2, 24(sp)
  lw a3, 28(sp)
  lw a4, 32(sp)
  lw a5, 36(sp)
  lw a6, 40(sp)
  lw a7, 44(sp)
  addi sp, sp, 64

  reti
```

Poznámka:

* toto je pragmatický minimalizovaný IRQ stub
* register save set môžeš neskôr rozšíriť
* pre prvý bring-up je to dobrý základ

---

# 5. ISR framework v C

Teraz potrebuješ jednoduchý C handler.

## `tests/golden/fixtures/picorv32_soc/fw/irq.h`

```c
#ifndef IRQ_H
#define IRQ_H

void irq_handler(void);

#endif
```

## `tests/golden/fixtures/picorv32_soc/fw/irq.c`

```c
#include <stdint.h>
#include "soc_irq.h"

#define IRQ0_PENDING_REG (*(volatile uint32_t*)(0x40001000u))
#define IRQ0_ENABLE_REG  (*(volatile uint32_t*)(0x40001004u))
#define IRQ0_ACK_REG     (*(volatile uint32_t*)(0x4000100Cu))

volatile uint32_t g_irq_count = 0;
volatile uint32_t g_last_pending = 0;

void irq_handler(void) {
    uint32_t pending = IRQ0_PENDING_REG;
    g_last_pending = pending;
    g_irq_count++;

    if (pending & (1u << GPIO0_CHANGED_IRQ)) {
        IRQ0_ACK_REG = (1u << GPIO0_CHANGED_IRQ);
    }
}
```

Toto robí presne to, čo chceš:

* prečíta pending
* uloží si ho
* incrementne counter
* ackne GPIO interrupt

---

# 6. Firmware main s reálnym IRQ flow

Teraz `main()`:

* povolí source v IRQ controllery
* povolí IRQ v CPU
* beží normálny loop
* ISR mení systémový stav

Keďže nechceme hneď robustnú platform knižnicu, spravíme malé helpery.

## `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include <stdint.h>
#include "soc_map.h"
#include "soc_irq.h"
#include "irq.h"

#define IRQ0_PENDING_REG (*(volatile uint32_t*)(0x40001000u))
#define IRQ0_ENABLE_REG  (*(volatile uint32_t*)(0x40001004u))
#define IRQ0_ACK_REG     (*(volatile uint32_t*)(0x4000100Cu))

extern volatile uint32_t g_irq_count;
extern volatile uint32_t g_last_pending;

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

static inline void cpu_enable_irqs(void) {
    /* PicoRV32 custom IRQ enable instruction path is implementation-specific.
       For the first slice keep this as a hook. If your wrapper/core expects
       a different enable mechanism, replace here. */
    __asm__ volatile ("" ::: "memory");
}

int main(void) {
    uint32_t value = 0x01;
    uint32_t seen_irq_count = 0;

    IRQ0_ENABLE_REG = (1u << GPIO0_CHANGED_IRQ);
    cpu_enable_irqs();

    while (1) {
        GPIO0_VALUE_REG = value;
        delay(100000);

        if (g_irq_count != seen_irq_count) {
            seen_irq_count = g_irq_count;
            value ^= 0x3F;
        } else {
            value = ((value << 1) & 0x3F);
            if (value == 0)
                value = 0x01;
        }

        delay(100000);
    }

    return 0;
}
```

Dôležitá poznámka:

* `cpu_enable_irqs()` je tu zatiaľ placeholder hook
* v ďalšom spevňovacom kroku ho naviažeš na presný PicoRV32 IRQ enable mechanizmus, ktorý používaš
* tento slice ti už pripraví architektúru firmware a entry path

---

# 7. Praktickejšia verzia pre prvý bring-up

Ak chceš, aby toto fungovalo hneď aj bez riešenia CPU-side IRQ enable detailov, môžeš spraviť prechodný režim:

* ISR framework mať hotový
* ale `main()` stále polluje `IRQ0_PENDING_REG`
* a ISR path ponechať pripravenú

To je veľmi pragmatické. Ak chceš čisto “reálny IRQ”, potom treba dotiahnuť presný PicoRV32 enable/ABI detail.

Ja by som odporučil:

* teraz implementovať **entry + handler + linker**
* a CPU enable mechaniku spevniť hneď v ďalšom mikro-kroku

---

# 8. Wrapper cleanup pre IRQ

Wrapper by mal mať:

* `irq` port korektne pripojený
* `PROGADDR_IRQ` parameter nastavený z descriptoru alebo project params
* bez konfliktu medzi memory handshake a interrupt path

To už v zásade máš, ale skontroluj:

## checklist

* `ENABLE_IRQ = true`
* `PROGADDR_IRQ = 0x00000010`
* `irq[31:0]` je pripojené z `irq_ctrl.cpu_irq_o`
* `LATCHED_MEM_RDATA = false` je konzistentné s wrapper handshake
* `mem_ready` ide len z fabric response
* `mem_rdata` je stabilné pri `mem_ready`

---

# 9. Descriptor example s IRQ-ready params

## `tests/golden/fixtures/picorv32_soc/ip/picorv32_min.cpu.yaml`

Skontroluj, že má:

```yaml
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
```

---

# 10. Smoke TB jemne rozšír

Keď už máš IRQ infraštruktúru, zmysel dáva pozrieť aspoň hierarchicky na IRQ state, ak je to jednoduché.

## update `tb_soc_top.sv`

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
    forever #10 SYS_CLK = ~SYS_CLK;
  end

  initial begin
    RESET_N = 1'b0;
    repeat (10) @(posedge SYS_CLK);
    RESET_N = 1'b1;
  end

  logic [5:0] leds_a, leds_b, leds_c;

  initial begin
    $display("[TB] starting simulation");

    repeat (4000) @(posedge SYS_CLK);
    leds_a = ONB_LEDS;

    repeat (4000) @(posedge SYS_CLK);
    leds_b = ONB_LEDS;

    repeat (4000) @(posedge SYS_CLK);
    leds_c = ONB_LEDS;

    $display("[TB] LED states: %b %b %b", leds_a, leds_b, leds_c);

    if (^leds_c === 1'bx)
      $fatal(1, "[TB] LED state contains X");

    if (leds_a == leds_b && leds_b == leds_c)
      $fatal(1, "[TB] LED state did not evolve");

    $finish;
  end

endmodule

`default_nettype wire
```

Toto už stačí na prvé smoke regression.

---

# 11. Integration test názov a očakávanie

## `tests/integration/test_sim_picorv32_irq_smoke.py`

```python
import shutil
import pytest

from socfw.build.context import BuildRequest
from socfw.build.two_pass_flow import TwoPassBuildFlow
from socfw.tools.sim_runner import SimRunner


@pytest.mark.skipif(
    shutil.which("iverilog") is None or shutil.which("riscv32-unknown-elf-gcc") is None,
    reason="missing simulation or riscv toolchain",
)
def test_sim_picorv32_irq_smoke(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok
    assert (out_dir / "fw" / "firmware.hex").exists()
    assert (out_dir / "sw" / "soc_irq.h").exists()

    sim = SimRunner().run_iverilog(str(out_dir))
    assert sim.ok
```

---

# 12. Dôležitá poznámka o “real IRQ” úprimne

Aby som bol presný:

* vyššie som pripravil **reálnu architektúru IRQ entry path**
* ale **presný CPU-side enable/servis detail** pre PicoRV32 závisí od zvoleného wrapper/config štýlu a je vhodné ho overiť proti konkrétnej verzii PicoRV32, ktorú použiješ

To je ten kus, ktorý by som spravil v nasledujúcom mikro-kroku ako:

* “PicoRV32 IRQ ABI verification”
* s konkrétnym wrapper testom

Architektúra, ktorú máš po tomto kroku, je však správna a stabilná.

---

# 13. Čo týmto získaš

Po tomto kroku už máš:

* linker pripravený na IRQ entry
* startup ASM
* ISR framework
* centralizovaný IRQ controller
* firmware-visible enable/pending/ack flow
* základ pre skutočný interrupt-driven SoC

To je veľmi silný milestone.

---

# 14. Čo by som spravil hneď potom

Teraz sú podľa mňa dve najlepšie možnosti:

### A

**PicoRV32 IRQ ABI verification + exact enable sequence**

* potvrdiť presný CPU-side interrupt enable postup
* doladiť `cpu_enable_irqs()`
* validovať ISR return path

### B

**protocol adapter branch**

* AXI-lite slave wrapper
* Wishbone wrapper
* ukázať skutočnú rozšíriteľnosť frameworku

Môj praktický odporúčaný ďalší krok je:

👉 **A — PicoRV32 IRQ ABI verification + exact enable sequence**

Lebo tým uzavrieš prvý naozaj dôveryhodný interrupt-driven demo SoC.

Ak chceš, ďalšia správa môže byť presne:
**PicoRV32 IRQ ABI verification checklist + wrapper/API adjustments + final IRQ-enabled firmware path**
