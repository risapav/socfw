Super. Ideme na:

# PicoRV32 IRQ ABI verification + exact enable sequence + wrapper/API adjustments + finálny IRQ-enabled firmware path

Toto je posledný kritický krok, aby bol prvý interrupt-driven SoC slice nielen pekne navrhnutý, ale aj **dôveryhodný**.

Budem veľmi presný a férový:
pri PicoRV32 je najcitlivejšia časť nie samotný SoC framework, ale **presný CPU-side interrupt model** a to, ako ho chceš používať:

* čisto “native PicoRV32 IRQ”
* alebo “simplified external interrupt convention cez wrapper”

Pre framework je lepšie mať to **explicitne opísané v CPU deskriptore a wrapper contracte**, nie rozliate po firmvéri.

---

# 1. Kde je skutočný problém

Doteraz máme pripravené:

* IRQ controller
* pending/enable/ack registre
* IRQ line do CPU
* linker script s `.text.irq`
* startup stub
* ISR skeleton

To všetko je správne.

Citlivý bod je:

## CPU-side interrupt enable / entry contract

Pri PicoRV32 musí byť jasné:

* ako sa IRQ povoľuje,
* čo presne CPU posiela do handlera,
* ako sa vracia z IRQ,
* či používaš:

  * interný PicoRV32 custom IRQ model,
  * alebo wrapperom zjednodušený model.

---

# 2. Odporúčané architektonické rozhodnutie

Pre framework odporúčam toto:

## fáza 1 — wrapper-defined IRQ ABI

Neopierať sa hneď o plný “raw PicoRV32 software ABI” v aplikácii, ale definovať si **malý stabilný wrapper contract**:

* CPU wrapper exponuje:

  * externú 32-bit IRQ linku
* firmware dostane:

  * pevný entry bod
  * jeden C handler `irq_handler()`
* wrapper + startup definujú:

  * save/restore minimálneho kontextu
  * návrat z IRQ

To je oveľa lepšie než hneď spoliehať sa na implicitné jemnosti konkrétnej verzie PicoRV32.

Teda:
**framework contract > implicit CPU folklore**

---

# 3. Čo má byť explicitne v CPU descriptor meta

Rozšír CPU descriptor o IRQ ABI metadata.

## update `socfw/config/cpu_schema.py`

Pridaj:

```python
class CpuIrqAbiSchema(BaseModel):
    kind: Literal["picorv32_native", "wrapper_minimal"]
    irq_entry_addr: int = 0x10
    enable_mechanism: Literal["wrapper_hook", "native_sw"] = "wrapper_hook"
    return_instruction: str = "reti"


class CpuDescriptorSchema(BaseModel):
    version: Literal[2]
    kind: Literal["cpu"]
    cpu: CpuDescriptorMetaSchema
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterSchema | None = None
    irq_abi: CpuIrqAbiSchema | None = None
    default_params: dict = Field(default_factory=dict)
    artifacts: list[str] = Field(default_factory=list)
    notes: list[str] = Field(default_factory=list)
```

---

## update `socfw/model/cpu_desc.py`

Pridaj:

```python
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class CpuIrqAbi:
    kind: str
    irq_entry_addr: int = 0x10
    enable_mechanism: str = "wrapper_hook"
    return_instruction: str = "reti"


@dataclass(frozen=True)
class CpuDescriptor:
    name: str
    module: str
    family: str
    clock_port: str = "SYS_CLK"
    reset_port: str = "RESET_N"
    irq_port: str | None = None
    bus_master: CpuBusMasterDesc | None = None
    irq_abi: CpuIrqAbi | None = None
    default_params: dict[str, Any] = field(default_factory=dict)
    artifacts: tuple[str, ...] = ()
    meta: dict[str, Any] = field(default_factory=dict)
```

---

## update `socfw/config/cpu_loader.py`

Pri skladaní descriptoru:

```python
from socfw.model.cpu_desc import CpuBusMasterDesc, CpuDescriptor, CpuIrqAbi
```

A doplň:

```python
            irq_abi=(
                CpuIrqAbi(
                    kind=doc.irq_abi.kind,
                    irq_entry_addr=doc.irq_abi.irq_entry_addr,
                    enable_mechanism=doc.irq_abi.enable_mechanism,
                    return_instruction=doc.irq_abi.return_instruction,
                )
                if doc.irq_abi is not None else None
            ),
```

---

# 4. PicoRV32 descriptor s ABI

## update `tests/golden/fixtures/picorv32_soc/ip/picorv32_min.cpu.yaml`

Pridaj:

```yaml
irq_abi:
  kind: wrapper_minimal
  irq_entry_addr: 0x10
  enable_mechanism: wrapper_hook
  return_instruction: reti
```

Týmto je už explicitné, ako má firmware/runtime fungovať.

---

# 5. Linker script nemá mať hardcoded `0x10` navždy

Doteraz sme ho dali natvrdo. Lepšie je naviazať ho na `irq_entry_addr` z CPU descriptoru.

Na to rozšírime `SoftwareIR`.

## update `socfw/ir/software.py`

Pridaj do `SoftwareIR`:

```python
    irq_entry_addr: int = 0x10
```

## update `socfw/builders/software_ir_builder.py`

Pri tvorbe IR:

```python
        cpu_desc = system.cpu_desc()
        irq_entry_addr = 0x10
        if cpu_desc is not None and cpu_desc.irq_abi is not None:
            irq_entry_addr = cpu_desc.irq_abi.irq_entry_addr

        ir = SoftwareIR(
            board_name=system.board.board_id,
            sys_clk_hz=system.board.sys_clock.frequency_hz,
            ram_base=system.ram.base,
            ram_size=system.ram.size,
            reset_vector=system.reset_vector,
            stack_percent=system.stack_percent,
            irq_entry_addr=irq_entry_addr,
        )
```

## update `socfw/templates/sections.lds.j2`

Namiesto `0x10` použi:

```jinja2
  . = ORIGIN(RAM) + 0x{{ "%X"|format(sw.irq_entry_addr) }};
```

---

# 6. Startup ASM nemá byť univerzálne “magické”

Tvoja súčasná verzia je dobrá ako slice, ale odporúčam urobiť z nej už jasný contract:

* `_start`
* `irq_entry`
* `irq_handler`

A dať jasný komentár, že register-save set je minimal bring-up set.

## update `tests/golden/fixtures/picorv32_soc/fw/start.S`

```asm
.section .text.start
.global _start
_start:
  la sp, _stack_top
  call main
1:
  j 1b

/* Minimal wrapper-defined IRQ ABI entry.
   This is a bring-up runtime, not yet a full general-purpose ABI layer. */
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

Toto je dôležité najmä dokumentačne — aby bolo jasné, že je to vedomý ABI contract.

---

# 7. `cpu_enable_irqs()` musí byť explicitne framework policy

Aktuálne je placeholder. To je v poriadku len krátkodobo. Lepšie je zaviesť malý header, ktorý je CPU-specific.

## nový `tests/golden/fixtures/picorv32_soc/fw/cpu_irq.h`

```c
#ifndef CPU_IRQ_H
#define CPU_IRQ_H

static inline void cpu_enable_irqs(void) {
    /* Wrapper-defined hook for current PicoRV32 integration slice.
       Replace with verified native enable sequence once finalized. */
    __asm__ volatile ("" ::: "memory");
}

#endif
```

## update `main.c`

```c
#include "cpu_irq.h"
```

Týmto:

* app firmware neobsahuje špecifický magický detail,
* CPU-specific policy sa presunie do malej vrstvy.

To je architektonicky správne.

---

# 8. Lepší ISR framework

Teraz namiesto jedného monolitického handlera sprav malý dispatch layer.

## nový `tests/golden/fixtures/picorv32_soc/fw/isr.h`

```c
#ifndef ISR_H
#define ISR_H

#include <stdint.h>

typedef void (*isr_fn_t)(void);

void isr_init(void);
void isr_register(unsigned irq_id, isr_fn_t fn);
void irq_handler(void);

#endif
```

## nový `tests/golden/fixtures/picorv32_soc/fw/isr.c`

```c
#include "isr.h"
#include <stdint.h>

#define IRQ0_PENDING_REG (*(volatile uint32_t*)(0x40001000u))
#define IRQ0_ACK_REG     (*(volatile uint32_t*)(0x4000100Cu))

static isr_fn_t g_isr_table[32];

void isr_init(void) {
    for (unsigned i = 0; i < 32; ++i)
        g_isr_table[i] = 0;
}

void isr_register(unsigned irq_id, isr_fn_t fn) {
    if (irq_id < 32)
        g_isr_table[irq_id] = fn;
}

void irq_handler(void) {
    uint32_t pending = IRQ0_PENDING_REG;

    for (unsigned i = 0; i < 32; ++i) {
        if ((pending & (1u << i)) && g_isr_table[i]) {
            g_isr_table[i]();
            IRQ0_ACK_REG = (1u << i);
        }
    }
}
```

Toto je už veľmi slušný minimalistický ISR framework.

---

# 9. GPIO ISR example

## update `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include <stdint.h>
#include "soc_map.h"
#include "soc_irq.h"
#include "cpu_irq.h"
#include "isr.h"

#define IRQ0_ENABLE_REG  (*(volatile uint32_t*)(0x40001004u))

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

static volatile uint32_t g_blink_mode = 0;
static volatile uint32_t g_value = 0x01;

static void gpio_changed_isr(void) {
    g_blink_mode ^= 1u;
}

int main(void) {
    isr_init();
    isr_register(GPIO0_CHANGED_IRQ, gpio_changed_isr);

    IRQ0_ENABLE_REG = (1u << GPIO0_CHANGED_IRQ);
    cpu_enable_irqs();

    while (1) {
        GPIO0_VALUE_REG = g_value;
        delay(100000);

        if (g_blink_mode) {
            g_value ^= 0x3F;
        } else {
            g_value = ((g_value << 1) & 0x3F);
            if (g_value == 0)
                g_value = 0x01;
        }

        delay(100000);
    }

    return 0;
}
```

Toto už je veľmi blízko “real interrupt-driven firmware shape”.

---

# 10. Report/diagnostics: CPU IRQ ABI explain

Keď už je IRQ ABI explicitná v CPU descriptoroch, oplatí sa ju pridať aj do explain/report vrstvy.

## update `socfw/reports/explain.py`

Pridaj metódu:

```python
    def explain_cpu_irq(self, system) -> str:
        cpu = system.cpu
        desc = system.cpu_desc()
        if cpu is None or desc is None or desc.irq_abi is None:
            return "No CPU IRQ ABI configured."

        abi = desc.irq_abi
        return (
            f"CPU IRQ ABI:\n"
            f"- CPU type: {cpu.type_name}\n"
            f"- ABI kind: {abi.kind}\n"
            f"- IRQ entry address: 0x{abi.irq_entry_addr:08X}\n"
            f"- Enable mechanism: {abi.enable_mechanism}\n"
            f"- Return instruction: {abi.return_instruction}"
        )
```

## update `socfw/cli/main.py`

Rozšír `explain` topics:

```python
    e.add_argument("topic", choices=["clocks", "cpu-irq"])
```

A v handlery:

```python
    elif args.topic == "cpu-irq":
        print(expl.explain_cpu_irq(loaded.value))
```

To je veľmi užitočné pri debugovaní.

---

# 11. ABI verification checklist

Toto by som naozaj uložil ako checkpoint.

# PicoRV32 IRQ ABI verification checklist

## Framework-side done

* CPU descriptor carries IRQ ABI metadata
* linker script places `.text.irq` at descriptor-defined IRQ entry address
* startup ASM provides `irq_entry`
* firmware uses CPU-specific `cpu_irq.h`
* ISR dispatch layer is separated from app logic
* IRQ controller provides pending/enable/ack MMIO interface

## To verify against concrete PicoRV32 version

* exact interrupt enable mechanism for selected core config
* exact semantics of `reti` in this integration
* whether additional registers must be preserved in IRQ stub
* whether IRQ nesting is possible or must be prevented
* whether wrapper needs explicit synchronization for IRQ line timing
* whether PROGADDR_IRQ and reset mapping match actual CPU behavior in sim

## Acceptance test

* build-fw passes
* firmware.hex generated
* simulation shows LED mode change driven by ISR path
* IRQ pending bit latches
* IRQ ACK clears pending
* no deadlock in CPU after first IRQ

---

# 12. Čo je po tomto už hotové

Po tomto kroku máš už veľmi silný základ:

* descriptor-driven CPU
* IRQ ABI explicitne modelovanú
* IRQ controller
* firmware runtime vrstvu
* ISR dispatch
* app-level handler registráciu
* build + report + sim smoke flow

To je už naozaj presvedčivý mini-SoC framework.

---

# 13. Úprimne: čo ešte nie je “produkčne uzavreté”

Dve veci by som stále považoval za otvorené:

## 1. presný PicoRV32 native IRQ enable detail

Ten treba potvrdiť proti konkrétnej verzii CPU/wrapperu.

## 2. general-purpose ABI save/restore set

Teraz máš bring-up stub. Produkčne by si chcel:

* jasne definovaný preserved register set
* možno generovanie podľa CPU family

To už je ale spevňovanie, nie architektonický dlh.

---

# 14. Môj odporúčaný ďalší krok

Teraz už má zmysel ísť jedným z dvoch smerov:

### A

**AXI-lite / Wishbone adapter branch**

* ukážeš, že architektúra je naozaj rozšíriteľná

### B

**repo hardening**

* packaging
* test matrix
* golden snapshots
* CI layout
* docs pre používateľov frameworku

Môj praktický odporúčaný ďalší krok je:

👉 **A — AXI-lite bridge/plugin slice**

Lebo to bude najlepší dôkaz, že nový framework je naozaj navrhnutý správne a nie je len lepšie uprataný single-bus generator.

Ak chceš, ďalšia správa môže byť presne:
**AXI-lite → simple_bus bridge + adapter plugin + example peripheral integration**
