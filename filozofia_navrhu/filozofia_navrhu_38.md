Super. Ideme na:

# real IRQ controller block + enable/mask/pending registre + PicoRV32 IRQ firmware path

Toto je správny ďalší krok, lebo teraz už máš:

* IRQ signály z periférií,
* `irq_pending` register pattern,
* CPU descriptor,
* firmware build flow,
* smoke sim.

Chýba dotiahnuť z toho **skutočný interrupt subsystem**, nie len polling.

Cieľ tohto kroku:

* centrálne IRQ controller IP
* registre:

  * `pending`
  * `enable`
  * `mask/ack`
* IRQ line do CPU
* firmware, ktoré:

  * povolí IRQ
  * obslúži interrupt
  * ackne zdroj
* lepšia architektúra než priame “peripheral → cpu_irq bus”

To je už veľmi blízko reálnemu malému SoC-u.

---

# 1. Architektúrne rozhodnutie

Odporúčam prejsť z:

```text
gpio irq signal -> irq_combiner -> cpu irq
```

na:

```text
peripheral irq signals -> irq_controller (bus slave) -> cpu irq
```

To dáva:

* software viditeľný stav IRQ
* maskovanie
* acknowledge
* centralizovaný interrupt model
* možnosť neskôr pridať priority/vectoring

To je výrazne lepší základ.

---

# 2. Nový IRQ controller IP

Navrhujem nový generický blok:

## funkcie

* `src_irq_i[N-1:0]`
* `cpu_irq_o[N-1:0]`
* bus slave interface
* registre:

  * `PENDING`  offset `0x00`
  * `ENABLE`   offset `0x04`
  * `FORCE`    offset `0x08` voliteľne
  * `ACK`      offset `0x0C`

## správanie

* `pending <= pending | src_irq_i`
* `ack write` čistí bity
* `cpu_irq_o = pending & enable`

To je jednoduché a veľmi užitočné.

---

# 3. IP descriptor

## `tests/golden/fixtures/picorv32_soc/ip/irq_ctrl.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: irq_ctrl
  module: irq_ctrl
  category: interrupt

origin:
  kind: source
  packaging: plain_rtl

integration:
  needs_bus: true
  generate_registers: false
  instantiate_directly: true
  dependency_only: false

reset:
  port: RESET_N
  active_high: false

clocking:
  primary_input_port: SYS_CLK
  additional_input_ports: []
  outputs: []

artifacts:
  synthesis:
    - tests/golden/fixtures/picorv32_soc/rtl/irq_ctrl.sv
  simulation: []
  metadata: []

registers:
  - name: pending
    offset: 0
    width: 32
    access: ro
    hw_source: pending
    desc: latched interrupt pending bits

  - name: enable
    offset: 4
    width: 32
    access: rw
    reset: 0
    desc: interrupt enable bits

  - name: ack
    offset: 12
    width: 32
    access: wo
    reset: 0
    write_pulse: true
    desc: write-1-to-clear pending bits
```

Poznámka:

* `pending` je HW-driven status
* `enable` je normálny RW register
* `ack` je command register cez `write_pulse`

---

# 4. IRQ controller RTL

## `tests/golden/fixtures/picorv32_soc/rtl/irq_ctrl.sv`

```systemverilog
`default_nettype none

module irq_ctrl (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  bus_if.slave       bus,
  input  wire [31:0] src_irq_i,
  output wire [31:0] cpu_irq_o
);

  logic [31:0] reg_enable;
  logic [31:0] reg_ack;
  logic        reg_ack_we;

  logic [31:0] hw_pending;
  logic [31:0] rdata;
  logic        ready;

  irq0_regs u_regs (
    .SYS_CLK        (SYS_CLK),
    .RESET_N        (RESET_N),
    .addr_i         (bus.addr[11:2]),
    .wdata_i        (bus.wdata),
    .we_i           (bus.we),
    .valid_i        (bus.valid),
    .rdata_o        (rdata),
    .ready_o        (ready),
    .hw_pending     (hw_pending),
    .reg_enable     (reg_enable),
    .reg_ack        (reg_ack),
    .reg_ack_we     (reg_ack_we)
  );

  logic [31:0] pending_q;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      pending_q <= 32'h0;
    end else begin
      pending_q <= pending_q | src_irq_i;
      if (reg_ack_we)
        pending_q <= (pending_q | src_irq_i) & ~reg_ack;
    end
  end

  assign hw_pending = pending_q;
  assign cpu_irq_o = pending_q & reg_enable;

  assign bus.rdata = rdata;
  assign bus.ready = ready;

endmodule

`default_nettype wire
```

---

# 5. Integrácia do SoC fixture

Do `project.yaml` pridaj IRQ controller ako normálny slave:

## update `tests/golden/fixtures/picorv32_soc/project.yaml`

```yaml
  - instance: irq0
    type: irq_ctrl
    bus:
      fabric: main
      base: 0x40001000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
```

Tým pádom:

* CPU pristupuje na IRQ controller cez bus
* GPIO ostáva na `0x40000000`
* IRQ controller napr. na `0x40001000`

---

# 6. Wiring periférnych IRQ do controllera

Doteraz sa IRQ viedli priamo do combineru. Teraz ich chceme viesť do `irq_ctrl.src_irq_i`.

Najjednoduchšie:

* zrušiť `irq_combiner`
* v `RtlIRBuilder` zistiť, či existuje instance typu `irq_ctrl`
* ak áno, pripojiť tam agregovaný vector

---

# 7. Jednoduchý IRQ vector wiring v RTL builderi

## update `socfw/builders/rtl_ir_builder.py`

Po vytvorení periférnych inštancií doplň:

```python
        irq_sources = []
        for mod in system.project.modules:
            ip = system.ip_catalog.get(mod.type_name)
            if ip is None:
                continue
            for irq in ip.meta.get("irqs", []):
                irq_name = str(irq["name"])
                irq_id = int(irq["id"])
                sig = f"irq_{mod.instance}_{irq_name}"
                irq_sources.append((irq_id, sig))
```

Potom vytvor wire:

```python
        if irq_sources:
            max_irq = max(i for i, _ in irq_sources)
            rtl.add_wire_once(RtlWire(name="irq_vector", width=max_irq + 1, comment="aggregated irq vector"))

            for irq_id, sig in irq_sources:
                rtl.assigns.append(
                    RtlAssign(
                        lhs=f"irq_vector[{irq_id}]",
                        rhs=sig,
                        comment=f"IRQ source bit {irq_id}",
                    )
                )
```

A ak nájdeš `irq_ctrl` instance, pripoj:

```python
        for inst in rtl.instances:
            if inst.name == "irq0":
                inst.conns.append(RtlConn(port="src_irq_i", signal="irq_vector"))
                inst.conns.append(RtlConn(port="cpu_irq_o", signal="cpu_irq"))
```

A CPU port už pripoj na `cpu_irq`.

Tým pádom:

* CPU dostane IRQ z controllera
* controller dostane raw IRQ zdroje

---

# 8. CPU IRQ port

Tvoj CPU descriptor už má `irq_port`. Firmware path zostáva rovnaký.

V `RtlIRBuilder` nech teda už CPU IRQ ide len z controllera, nie z combineru.

To znamená:

* `RtlIrqBuilder`
* `irq_combiner.sv`

môžeš teraz:

* buď odstrániť,
* alebo ponechať len pre fallback/debug mode.

Odporúčam pre čistotu:

* **nahradiť combiner controllerom**.

---

# 9. `soc_irq.h` bude užitočný

Teraz `soc_irq.h` už nebude len “zoznam názvov”, ale bude mať skutočný zmysel pre firmware.

Napríklad:

```c
#define GPIO0_CHANGED_IRQ 0U
```

A firmware bude vedieť:

* `IRQ0_ENABLE_REG = (1u << GPIO0_CHANGED_IRQ);`
* `IRQ0_ACK_REG = (1u << GPIO0_CHANGED_IRQ);`

---

# 10. Firmware demo s reálnym IRQ controllerom

Najprv ešte bez plného trap handlera spravíme poloreálny flow:

* enable interrupt source v controlleri
* poll CPU IRQ line cez MMIO pending bit
* ack cez controller register

To je hneď použiteľné.

## update `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include "soc_map.h"
#include "soc_irq.h"

#define IRQ0_PENDING_REG (*(volatile unsigned*)(0x40001000u))
#define IRQ0_ENABLE_REG  (*(volatile unsigned*)(0x40001004u))
#define IRQ0_ACK_REG     (*(volatile unsigned*)(0x4000100Cu))

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

int main(void) {
    unsigned value = 0x01;

    IRQ0_ENABLE_REG = (1u << GPIO0_CHANGED_IRQ);

    while (1) {
        GPIO0_VALUE_REG = value;
        delay(100000);

        if (IRQ0_PENDING_REG & (1u << GPIO0_CHANGED_IRQ)) {
            IRQ0_ACK_REG = (1u << GPIO0_CHANGED_IRQ);
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

Toto už testuje:

* peripheral IRQ generation
* pending latch
* enable mask
* ack write pulse

---

# 11. Skutočný PicoRV32 IRQ path – ďalší level

Ak chceš naozaj “real interrupt”, ďalší krok po tomto je:

* nakonfigurovať PicoRV32 IRQ ABI správne
* pridať trap/IRQ entry
* dispatcher v ASM/C
* potvrdenie source cez IRQ controller

Ale zatiaľ by som to spravil dvojstupňovo:

1. **controller hotový**
2. až potom **CPU interrupt entry**

To je omnoho menej bolestivé.

---

# 12. Regblock contract už to podporuje

Tento návrh krásne ukazuje, že predchádzajúce kroky boli správne:

* `pending` ako `hw_source`
* `enable` ako `rw`
* `ack` ako `write_pulse`

To je presne sila toho contractu.

---

# 13. Smoke simulation harness

Tvoj existujúci TB stačí, ale môžeš ho mierne zlepšiť, aby:

* dlhšie bežal,
* overil zmenu LED patternu,
* prípadne cez hierarchical peek skontroloval `irq_vector`.

## update `tb_soc_top.sv`

```systemverilog
  logic [5:0] leds_a, leds_b, leds_c;

  initial begin
    $display("[TB] starting simulation");

    repeat (3000) @(posedge SYS_CLK);
    leds_a = ONB_LEDS;

    repeat (3000) @(posedge SYS_CLK);
    leds_b = ONB_LEDS;

    repeat (3000) @(posedge SYS_CLK);
    leds_c = ONB_LEDS;

    $display("[TB] LED states: %b %b %b", leds_a, leds_b, leds_c);

    if (^leds_c === 1'bx)
      $fatal(1, "[TB] LED state contains X");

    if (leds_a == leds_b && leds_b == leds_c)
      $fatal(1, "[TB] LED state did not evolve");

    $finish;
  end
```

---

# 14. Čo týmto získaš

Po tomto kroku máš:

* centrálne IRQ riadenie
* enable/mask/pending/ack model
* periférie pripojené do IRQ fabricu
* firmware-visible interrupt subsystem
* architektúru pripravenú na skutočný interrupt handler

To je veľmi veľký skok v kvalite návrhu.

---

# 15. Čo by som spravil hneď potom

Najlepší ďalší krok teraz je už podľa mňa:

### možnosť A

**skutočný PicoRV32 interrupt entry path**

* ASM trap entry
* C dispatcher
* ISR registration
* ack cez controller

### možnosť B

**bus adapter layer**

* AXI-lite → simple_bus
* Wishbone → simple_bus

Môj praktický odporúčaný ďalší krok je:

👉 **A — skutočný PicoRV32 interrupt entry path**

Lebo už máš celý HW základ pripravený a firmware sa tým posunie z polling demo na reálny interrupt-driven SoC.

Ak chceš, ďalšia správa môže byť presne:
**PicoRV32 real IRQ entry + ASM startup + minimal ISR framework + firmware example**
