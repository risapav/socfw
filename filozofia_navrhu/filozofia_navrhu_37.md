Super. Ideme na:

# error slave + wait-state slave + fabric robustness slice

Toto je správny ďalší krok, lebo spevníš samotný základ SoC-u ešte pred tým, než začneš pridávať ďalšie bus protokoly.

Cieľ:

* mať definované správanie pre **unmapped access**
* vedieť simulovať **wait-state slave**
* spevniť `simple_bus_fabric`
* pridať regression testy pre:

  * mapped read/write
  * unmapped read
  * wait-state response

Týmto sa `simple_bus` prestane správať ako len “demo bus” a začne byť použiteľný ako seriózny interný backbone.

---

# 1. Problém dnešného stavu

Aktuálny `simple_bus_fabric`:

* dekóduje slave podľa `BASE_ADDR` a `ADDR_MASK`
* ale nemá jasnú odpoveď, keď:

  * adresa netrafí žiadny slave
  * viac slave-ov by teoreticky trafilo naraz
  * slave vráti wait-state

To treba zadefinovať.

---

# 2. Cieľové správanie

Pre `simple_bus` by som odporučil toto:

## mapped access

* ak adresa trafí 1 slave:

  * request ide len tam
  * master čaká na `ready`
  * `rdata` ide z daného slave

## unmapped access

* request ide do **error slave**
* `ready=1`
* `rdata=32'hDEAD_BEEF`

## overlap

* overlap je **build-time error**
* nemá sa riešiť runtime prioritou

## wait-state

* fabric drží request do `ready`
* master dostane odpoveď až keď slave odpovie

Toto je čisté a dobre testovateľné.

---

# 3. Validation rule pre overlap

Ak to ešte nemáš striktne, pridaj pravidlo pre RAM + peripherals + slave regions.

## update `socfw/validate/rules/bus_rules.py`

```python
from __future__ import annotations

from socfw.core.diagnostics import Diagnostic, Severity
from socfw.validate.rules.base import ValidationRule


class DuplicateAddressRegionRule(ValidationRule):
    def validate(self, system) -> list[Diagnostic]:
        diags: list[Diagnostic] = []
        regs = []

        if system.ram is not None:
            regs.append(("ram", system.ram.base, system.ram.base + system.ram.size - 1))

        for mod in system.project.modules:
            if mod.bus is not None:
                regs.append((mod.instance, mod.bus.base, mod.bus.base + mod.bus.size - 1))

        for i, (n1, b1, e1) in enumerate(regs):
            for n2, b2, e2 in regs[i + 1:]:
                if not (e1 < b2 or e2 < b1):
                    diags.append(
                        Diagnostic(
                            code="BUS003",
                            severity=Severity.ERROR,
                            message=(
                                f"Address overlap between '{n1}' "
                                f"(0x{b1:08X}-0x{e1:08X}) and '{n2}' "
                                f"(0x{b2:08X}-0x{e2:08X})"
                            ),
                            subject="project.modules.bus",
                        )
                    )
        return diags
```

## `socfw/plugins/bootstrap.py`

Zaregistruj:

```python
from socfw.validate.rules.bus_rules import DuplicateAddressRegionRule
```

a:

```python
    reg.register_validator(DuplicateAddressRegionRule())
```

---

# 4. Error slave RTL

## `src/ip/bus/simple_bus_error_slave.sv`

```systemverilog
`default_nettype none

module simple_bus_error_slave (
  bus_if.master bus
);

  always_comb begin
    bus.ready = bus.valid;
    bus.rdata = 32'hDEAD_BEEF;
  end

endmodule : simple_bus_error_slave

`default_nettype wire
```

Toto je veľmi užitočný debug prvok. Pri unmapped access neskončíš v tichom lockupe.

---

# 5. Wait-state slave RTL

Pridaj malý testovací slave, ktorý odpovedá až po pár cykloch.

## `tests/golden/fixtures/picorv32_soc/rtl/wait_state_slave.sv`

```systemverilog
`default_nettype none

module wait_state_slave #(
  parameter int DELAY = 3
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave bus
);

  logic [$clog2(DELAY+1)-1:0] counter;
  logic pending;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      counter <= '0;
      pending <= 1'b0;
    end else begin
      if (bus.valid && !pending) begin
        pending <= 1'b1;
        counter <= DELAY[$clog2(DELAY+1)-1:0];
      end else if (pending) begin
        if (counter != 0)
          counter <= counter - 1'b1;
        else
          pending <= 1'b0;
      end
    end
  end

  always_comb begin
    bus.ready = pending && (counter == 0);
    bus.rdata = 32'h1234_5678;
  end

endmodule

`default_nettype wire
```

Toto je ideálne na smoke/regression test handshake.

---

# 6. Robustnejší fabric

Teraz upravíme fabric tak, aby:

* explicitne vedel o error slave
* route-oval len selected slave
* používal fallback na error slave

## update `src/ip/bus/simple_bus_fabric.sv`

```systemverilog
`default_nettype none

module simple_bus_fabric #(
  parameter int NSLAVES = 1,
  parameter logic [NSLAVES*32-1:0] BASE_ADDR = '0,
  parameter logic [NSLAVES*32-1:0] ADDR_MASK = '0
)(
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave  m_bus,
  bus_if.master s_bus [NSLAVES],
  bus_if.master err_bus
);

  logic [NSLAVES-1:0] sel;
  logic any_sel;

  genvar i;
  generate
    for (i = 0; i < NSLAVES; i++) begin : g_decode
      wire [31:0] base = BASE_ADDR[i*32 +: 32];
      wire [31:0] mask = ADDR_MASK[i*32 +: 32];
      assign sel[i] = ((m_bus.addr & ~mask) == (base & ~mask));
    end
  endgenerate

  assign any_sel = |sel;

  always_comb begin
    m_bus.ready = 1'b0;
    m_bus.rdata = 32'h0;

    for (int j = 0; j < NSLAVES; j++) begin
      s_bus[j].addr  = m_bus.addr;
      s_bus[j].wdata = m_bus.wdata;
      s_bus[j].be    = m_bus.be;
      s_bus[j].we    = m_bus.we;
      s_bus[j].valid = m_bus.valid & sel[j];
    end

    err_bus.addr  = m_bus.addr;
    err_bus.wdata = m_bus.wdata;
    err_bus.be    = m_bus.be;
    err_bus.we    = m_bus.we;
    err_bus.valid = m_bus.valid & ~any_sel;

    if (any_sel) begin
      for (int j = 0; j < NSLAVES; j++) begin
        if (sel[j]) begin
          m_bus.ready = s_bus[j].ready;
          m_bus.rdata = s_bus[j].rdata;
        end
      end
    end else begin
      m_bus.ready = err_bus.ready;
      m_bus.rdata = err_bus.rdata;
    end
  end

endmodule : simple_bus_fabric
`default_nettype wire
```

---

# 7. RTL IR pre error interface

Treba pridať error bus interface do fabric buildera.

## update `socfw/builders/rtl_bus_builder.py`

Uprav `build_interfaces()`:

```python
    def build_interfaces(self, plan) -> list[RtlInterfaceInstance]:
        result: list[RtlInterfaceInstance] = []

        for fabric_name, endpoints in plan.fabrics.items():
            for ep in endpoints:
                if ep.protocol == "simple_bus":
                    result.append(
                        RtlInterfaceInstance(
                            if_type="bus_if",
                            name=f"if_{ep.instance}_{fabric_name}",
                            comment=f"{ep.role} endpoint on {fabric_name}",
                        )
                    )
            result.append(
                RtlInterfaceInstance(
                    if_type="bus_if",
                    name=f"if_error_{fabric_name}",
                    comment=f"error slave for {fabric_name}",
                )
            )
        return result
```

A `build_fabrics()` doplň:

```python
            fabric.ports.append(
                RtlFabricPort(
                    port_name="err_bus",
                    interface_name=f"if_error_{fabric_name}",
                    modport="master",
                    index=None,
                )
            )
```

---

# 8. Fabric template update

## `socfw/templates/soc_top.sv.j2`

Bus fabric sekcia už podporuje indexed aj non-indexed porty. `err_bus` bude bez indexu, takže by to malo fungovať automaticky, ak template používa podmienku na `index`.

Ak máš:

```jinja2
.{{ p.port_name }}{% if p.index is not none %}[{{ p.index }}]{% endif %}(...)
```

tak netreba meniť nič.

---

# 9. Error slave instance v top

Treba ho reálne inštanciovať. Najjednoduchšie: pridaj fabric-adjacent pseudo-instance do `RtlModuleIR`.

## update `socfw/builders/rtl_ir_builder.py`

Po `rtl.fabrics.extend(...)` doplň:

```python
        if design.interconnect is not None:
            for fabric_name in design.interconnect.fabrics.keys():
                rtl.instances.append(
                    RtlInstance(
                        module="simple_bus_error_slave",
                        name=f"error_{fabric_name}",
                        conns=[],
                        bus_conns=[
                            RtlBusConn(
                                port="bus",
                                interface_name=f"if_error_{fabric_name}",
                                modport="slave",
                            )
                        ],
                        comment=f"error slave for {fabric_name}",
                    )
                )
```

A na konci extra sources:

```python
        if rtl.fabrics and "src/ip/bus/simple_bus_error_slave.sv" not in rtl.extra_sources:
            rtl.extra_sources.append("src/ip/bus/simple_bus_error_slave.sv")
```

---

# 10. Wait-state test peripheral descriptor

Pridaj testovací IP.

## `tests/golden/fixtures/picorv32_soc/ip/wait_state_slave.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: wait_state_slave
  module: wait_state_slave
  category: test

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
    - tests/golden/fixtures/picorv32_soc/rtl/wait_state_slave.sv
  simulation: []
  metadata: []
```

---

# 11. Fixture s wait-state slave

Do `picorv32_soc/project.yaml` doplň ďalší modul:

```yaml
  - instance: slow0
    type: wait_state_slave
    params:
      DELAY: 4
    bus:
      fabric: main
      base: 0x50000000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
```

---

# 12. Firmware, ktoré trafí wait-state aj unmapped

Aktualizuj firmware, aby:

* zapisovalo do GPIO
* čítalo zo `slow0`
* skúsilo unmapped read

## update `tests/golden/fixtures/picorv32_soc/fw/main.c`

```c
#include "soc_map.h"

#define SLOW0_BASE      0x50000000u
#define UNMAPPED_ADDR   0x60000000u

static void delay(volatile unsigned count) {
    while (count--) {
        __asm__ volatile ("nop");
    }
}

static unsigned mmio_read(unsigned addr) {
    return *((volatile unsigned*)addr);
}

int main(void) {
    unsigned value = 0x01;
    volatile unsigned slow_value;
    volatile unsigned bad_value;

    while (1) {
        GPIO0_VALUE_REG = value;

        slow_value = mmio_read(SLOW0_BASE);
        bad_value  = mmio_read(UNMAPPED_ADDR);

        if ((GPIO0_IRQ_PENDING_REG & 0x1) != 0) {
            GPIO0_IRQ_PENDING_REG = 0x1;
            value ^= 0x3F;
        } else {
            value = ((value << 1) & 0x3F);
            if (value == 0)
                value = 0x01;
        }

        if (bad_value == 0xDEADBEEF)
            GPIO0_VALUE_REG = 0x2A;

        if (slow_value == 0x12345678)
            GPIO0_VALUE_REG ^= 0x15;

        delay(100000);
    }

    return 0;
}
```

Toto je veľmi dobrý živý smoke test:

* mapped slave s wait-state
* unmapped error slave
* GPIO viditeľný výstup

---

# 13. `soc_map.h` pre `slow0`

Ak chceš, stačí že region vznikne cez `software_ir_builder`, lebo nemá registre, ale base adresa už bude v docs/report. Na priame použitie vo firmware som dal `#define` ručne v C. To je v poriadku pre test fixture.

Neskôr môžeš generovať aj `*_BASE` pre všetky regiony bez registrov, ak to ešte už nemáš konzistentne.

---

# 14. Smoke TB kontrola unmapped/wait-state nepriamo

Testbench nemusí rozumieť CPU interným transakciám. Stačí, že:

* CPU sa nezasekne
* LED sa po čase zmenia
* nie sú `X`

Môžeš v TB trochu sprísniť kontrolu.

## update `tb_soc_top.sv`

```systemverilog
  logic [5:0] leds_prev;

  initial begin
    leds_prev = 6'h00;

    $display("[TB] starting simulation");
    repeat (5000) @(posedge SYS_CLK);
    leds_prev = ONB_LEDS;

    repeat (5000) @(posedge SYS_CLK);

    $display("[TB] LED state old=%b new=%b", leds_prev, ONB_LEDS);

    if (^ONB_LEDS === 1'bx) begin
      $fatal(1, "[TB] LED state contains X");
    end

    if (ONB_LEDS == leds_prev) begin
      $fatal(1, "[TB] LED state did not change");
    end

    $finish;
  end
```

Tým pádom sim test overí aspoň hrubý progres.

---

# 15. Integration test pre robustness

## `tests/integration/test_sim_picorv32_waitstate.py`

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
def test_sim_picorv32_waitstate(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/picorv32_soc/project.yaml"
    out_dir = tmp_path / "out"

    flow = TwoPassBuildFlow(templates_dir=templates)
    result = flow.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok
    assert (out_dir / "fw" / "firmware.hex").exists()

    sim = SimRunner().run_iverilog(str(out_dir))
    assert sim.ok
```

---

# 16. Report side-effect

Tým, že `slow0` aj error behavior sú v topológii prítomné, report/graph budú užitočnejšie:

* `slow0` sa objaví v address map
* `firmware` artefakty sa objavia v manifest/report
* `soc_graph.dot` bude mať bohatší SoC obraz

To je presne ten typ detailného reportingu, ktorý si chcel od začiatku.

---

# 17. Čo týmto získaš

Po tomto kroku už máš:

* explicit unmapped behavior
* explicit wait-state behavior
* regression-ready bus contract
* firmware, ktoré overuje viac než len LED write
* smoke simulation, ktorá už nie je len “či sa to skompiluje”

To veľmi spevňuje základ.

---

# 18. Čo by som spravil hneď potom

Teraz sú najlepšie dva ďalšie kroky:

### A

**protocol adapters**

* AXI-lite slave → simple_bus
* Wishbone slave → simple_bus

### B

**interrupt maturity**

* real PicoRV32 IRQ handling
* dispatch table
* pending/enable/mask registre

Môj praktický odporúčaný ďalší krok je:

👉 **B — real interrupt maturity**

Lebo už máš:

* IRQ wiring
* pending bit
* CPU descriptor
* firmware flow

Chýba len dotiahnuť to na skutočný interrupt path.

Ak chceš, ďalšia správa môže byť presne:
**real IRQ controller block + enable/mask/pending registers + PicoRV32 IRQ firmware path**
