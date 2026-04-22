Super. Ideme na:

# Wishbone bridge implementácia (RTL + planner + test fixture)

Toto je najlepší ďalší dôkaz, že bridge registry nie je len pekná architektúra na papieri, ale reálne funguje pre viac než jeden protokol.

Cieľ:

* doplniť **`simple_bus -> wishbone` bridge**
* pridať **Wishbone perifériu**
* mať **samostatný fixture**
* mať **integration test**
* ukázať, že planner vyberie správny bridge plugin automaticky

---

# 1. Cieľový datapath

Chceme mať:

```text
CPU (simple_bus)
  ↓
simple_bus fabric
  ↓
simple_bus_to_wishbone_bridge
  ↓
wishbone peripheral
```

A firmware stále robí len obyčajné MMIO na adresu periférie.

---

# 2. Wishbone interface

Ak si ešte nepridal interface, daj ho do `src/ip/bus/wishbone_if.sv`.

## `src/ip/bus/wishbone_if.sv`

```systemverilog
interface wishbone_if;
  logic [31:0] adr;
  logic [31:0] dat_w;
  logic [31:0] dat_r;
  logic [3:0]  sel;
  logic        we;
  logic        cyc;
  logic        stb;
  logic        ack;

  modport master (
    output adr, output dat_w, output sel, output we, output cyc, output stb,
    input  dat_r, input ack
  );

  modport slave (
    input  adr, input dat_w, input sel, input we, input cyc, input stb,
    output dat_r, output ack
  );
endinterface
```

---

# 3. Wishbone bridge RTL

Toto bude minimalistický single-request bridge.
Na prvý slice úplne stačí.

## `src/ip/bus/simple_bus_to_wishbone_bridge.sv`

```systemverilog
`default_nettype none

module simple_bus_to_wishbone_bridge (
  input  wire SYS_CLK,
  input  wire RESET_N,
  bus_if.slave      sbus,
  wishbone_if.master m_wb
);

  typedef enum logic [0:0] {
    S_IDLE,
    S_WAIT_ACK
  } state_t;

  state_t state;

  logic [31:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0]  req_be;
  logic        req_we;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      state    <= S_IDLE;
      req_addr <= 32'h0;
      req_wdata<= 32'h0;
      req_be   <= 4'h0;
      req_we   <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (sbus.valid) begin
            req_addr  <= sbus.addr;
            req_wdata <= sbus.wdata;
            req_be    <= sbus.be;
            req_we    <= sbus.we;
            state     <= S_WAIT_ACK;
          end
        end

        S_WAIT_ACK: begin
          if (m_wb.ack)
            state <= S_IDLE;
        end
      endcase
    end
  end

  always_comb begin
    sbus.ready = 1'b0;
    sbus.rdata = m_wb.dat_r;

    m_wb.adr   = (state == S_IDLE) ? sbus.addr  : req_addr;
    m_wb.dat_w = (state == S_IDLE) ? sbus.wdata : req_wdata;
    m_wb.sel   = (state == S_IDLE) ? sbus.be    : req_be;
    m_wb.we    = (state == S_IDLE) ? sbus.we    : req_we;
    m_wb.cyc   = (state == S_IDLE) ? sbus.valid : 1'b1;
    m_wb.stb   = (state == S_IDLE) ? sbus.valid : 1'b1;

    if (state == S_WAIT_ACK && m_wb.ack)
      sbus.ready = 1'b1;
  end

endmodule

`default_nettype wire
```

Poznámka:

* toto je jednoduchý one-outstanding-request bridge
* pre MMIO periférie je to úplne OK
* neskôr vieš doplniť timeout alebo error policy

---

# 4. Bridge planner plugin

Toto už máš načrtnuté. Ak nie, pridaj finálnu verziu.

## `socfw/plugins/bridges/simple_to_wishbone.py`

```python
from __future__ import annotations

from socfw.elaborate.bus_plan import PlannedBusBridge


class SimpleBusToWishboneBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "wishbone"
    bridge_module = "simple_bus_to_wishbone_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool:
        return fabric.protocol == "simple_bus" and iface.protocol == "wishbone"

    def plan_bridge(self, *, fabric, mod, ip, iface):
        return PlannedBusBridge(
            instance=f"bridge_{mod.instance}",
            module=self.bridge_module,
            src_protocol=self.src_protocol,
            dst_protocol=self.dst_protocol,
            src_fabric=fabric.name,
            dst_instance=mod.instance,
            dst_port=iface.port_name,
        )
```

---

# 5. Bootstrap registrácia

## update `socfw/plugins/bootstrap.py`

Skontroluj, že máš:

```python
from socfw.plugins.bridges.simple_to_wishbone import SimpleBusToWishboneBridgePlanner
```

a:

```python
reg.register_bridge_planner(SimpleBusToWishboneBridgePlanner())
```

---

# 6. RTL bus builder update pre Wishbone interface

Teraz treba, aby RTL builder vedel vytvoriť `wishbone_if` pre wishbone bridged periférie.

## update `socfw/builders/rtl_bus_builder.py`

V `build_interfaces()` doplň:

```python
        for br in plan.bridges:
            if br.dst_protocol == "axi_lite":
                result.append(
                    RtlInterfaceInstance(
                        if_type="axi_lite_if",
                        name=f"if_{br.dst_instance}_axil",
                        comment=f"AXI-lite side for {br.instance}",
                    )
                )
            elif br.dst_protocol == "wishbone":
                result.append(
                    RtlInterfaceInstance(
                        if_type="wishbone_if",
                        name=f"if_{br.dst_instance}_wb",
                        comment=f"Wishbone side for {br.instance}",
                    )
                )
```

V `build_bridge_instances()` doplň vetvu:

```python
        for br in plan.bridges:
            if br.dst_protocol == "axi_lite":
                result.append(
                    RtlInstance(
                        module=br.module,
                        name=br.instance,
                        conns=[],
                        bus_conns=[
                            RtlBusConn(
                                port="sbus",
                                interface_name=f"if_{br.instance}_{br.src_fabric}",
                                modport="slave",
                            ),
                            RtlBusConn(
                                port="m_axil",
                                interface_name=f"if_{br.dst_instance}_axil",
                                modport="master",
                            ),
                        ],
                        comment=f"{br.src_protocol} -> {br.dst_protocol} bridge",
                    )
                )
            elif br.dst_protocol == "wishbone":
                result.append(
                    RtlInstance(
                        module=br.module,
                        name=br.instance,
                        conns=[],
                        bus_conns=[
                            RtlBusConn(
                                port="sbus",
                                interface_name=f"if_{br.instance}_{br.src_fabric}",
                                modport="slave",
                            ),
                            RtlBusConn(
                                port="m_wb",
                                interface_name=f"if_{br.dst_instance}_wb",
                                modport="master",
                            ),
                        ],
                        comment=f"{br.src_protocol} -> {br.dst_protocol} bridge",
                    )
                )
```

---

# 7. RTL builder update pre wishbone peripherals

## update `socfw/builders/rtl_ir_builder.py`

V periférnej časti, kde riešiš `iface.protocol`, doplň:

```python
                elif iface.protocol == "wishbone" and design.interconnect is not None:
                    for br in design.interconnect.bridges:
                        if br.dst_instance == mod.instance:
                            bus_conns.append(RtlBusConn(
                                port=iface.port_name,
                                interface_name=f"if_{mod.instance}_wb",
                                modport="slave",
                            ))
```

A extra sources doplň:

```python
        if design.interconnect is not None and design.interconnect.bridges:
            if any(br.dst_protocol == "wishbone" for br in design.interconnect.bridges):
                if "src/ip/bus/simple_bus_to_wishbone_bridge.sv" not in rtl.extra_sources:
                    rtl.extra_sources.append("src/ip/bus/simple_bus_to_wishbone_bridge.sv")
                if "src/ip/bus/wishbone_if.sv" not in rtl.extra_sources:
                    rtl.extra_sources.append("src/ip/bus/wishbone_if.sv")
```

---

# 8. Wishbone periféria

Spravíme minimálny `wb_gpio`.

## `tests/golden/fixtures/wishbone_bridge_soc/ip/wb_gpio.ip.yaml`

```yaml
version: 2
kind: ip

ip:
  name: wb_gpio
  module: wb_gpio
  category: peripheral

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
    - tests/golden/fixtures/wishbone_bridge_soc/rtl/wb_gpio.sv
  simulation: []
  metadata: []

bus_interfaces:
  - port_name: wb
    protocol: wishbone
    role: slave
    addr_width: 32
    data_width: 32
```

## `tests/golden/fixtures/wishbone_bridge_soc/rtl/wb_gpio.sv`

```systemverilog
`default_nettype none

module wb_gpio (
  input  wire SYS_CLK,
  input  wire RESET_N,
  wishbone_if.slave wb,
  output logic [5:0] gpio_o
);

  logic [31:0] reg_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      reg_value <= 32'h0;
    else if (wb.cyc && wb.stb && wb.we)
      reg_value <= wb.dat_w;
  end

  always_comb begin
    wb.ack   = wb.cyc && wb.stb;
    wb.dat_r = reg_value;
  end

  assign gpio_o = reg_value[5:0];

endmodule

`default_nettype wire
```

---

# 9. Wishbone bridge fixture

Sprav samostatný fixture, nech je test čistý.

## `tests/golden/fixtures/wishbone_bridge_soc/project.yaml`

```yaml
version: 2
kind: project

project:
  name: wishbone_bridge_soc
  mode: soc
  board: qmtech_ep4ce55
  board_file: tests/golden/fixtures/wishbone_bridge_soc/board.yaml
  output_dir: build/gen
  debug: true

registries:
  ip:
    - tests/golden/fixtures/wishbone_bridge_soc/ip

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
  type: dummy_cpu
  fabric: main
  reset_vector: 0x00000000
  params: {}

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

modules:
  - instance: wb_gpio0
    type: wb_gpio
    bus:
      fabric: main
      base: 0x40003000
      size: 0x1000
    clocks:
      SYS_CLK: sys_clk
    bind:
      ports:
        gpio_o:
          target: board:onboard.leds

artifacts:
  emit: [rtl, timing, board, docs]
```

Použi rovnaké `board.yaml`, `dummy_cpu.cpu.yaml`, `soc_ram.sv` ako v predošlých fixtures.

---

# 10. Dummy CPU pre fixture

Ak už máš `dummy_cpu` fixture, len ho zdieľaj.
Ak nie, použi jednoduchý zapisujúci master.

## `tests/golden/fixtures/wishbone_bridge_soc/rtl/dummy_cpu.sv`

```systemverilog
`default_nettype none

module dummy_cpu (
  input  wire SYS_CLK,
  input  wire RESET_N,
  input  wire [31:0] irq,
  bus_if.master bus
);

  typedef enum logic [1:0] {
    S_IDLE,
    S_WRITE,
    S_DONE
  } state_t;

  state_t state;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      state <= S_IDLE;
    else begin
      case (state)
        S_IDLE:  state <= S_WRITE;
        S_WRITE: if (bus.ready) state <= S_DONE;
        default: state <= S_DONE;
      endcase
    end
  end

  always_comb begin
    bus.addr  = 32'h4000_3000;
    bus.wdata = 32'h0000_0015;
    bus.be    = 4'hF;
    bus.we    = 1'b0;
    bus.valid = 1'b0;

    if (state == S_WRITE) begin
      bus.we    = 1'b1;
      bus.valid = 1'b1;
    end
  end

endmodule

`default_nettype wire
```

---

# 11. CPU descriptor pre dummy CPU

## `tests/golden/fixtures/wishbone_bridge_soc/ip/dummy_cpu.cpu.yaml`

```yaml
version: 2
kind: cpu

cpu:
  name: dummy_cpu
  module: dummy_cpu
  family: test

clock_port: SYS_CLK
reset_port: RESET_N
irq_port: irq

bus_master:
  port_name: bus
  protocol: simple_bus
  addr_width: 32
  data_width: 32

default_params: {}

artifacts:
  - tests/golden/fixtures/wishbone_bridge_soc/rtl/dummy_cpu.sv
```

---

# 12. Integration test

## `tests/integration/test_build_wishbone_bridge_soc.py`

```python
from socfw.build.context import BuildRequest
from socfw.build.full_pipeline import FullBuildPipeline


def test_build_wishbone_bridge_soc(tmp_path):
    templates = "socfw/templates"
    project = "tests/golden/fixtures/wishbone_bridge_soc/project.yaml"
    out_dir = tmp_path / "out"

    pipeline = FullBuildPipeline(templates_dir=templates)
    result = pipeline.run(BuildRequest(project_file=project, out_dir=str(out_dir)))

    assert result.ok

    rtl = (out_dir / "rtl" / "soc_top.sv").read_text(encoding="utf-8")
    assert "simple_bus_to_wishbone_bridge" in rtl
    assert "wishbone_if" in rtl
    assert "wb_gpio" in rtl
```

---

# 13. Voliteľný sim smoke

Ak chceš, môžeš aj pre Wishbone bridge spraviť TB a overiť, že LED nie sú `X`, ale na prvý slice stačí build-time integračný test.

---

# 14. Validation test pre missing bridge

Teraz, keď máš generic bridge registry, je dobré overiť, že keď bridge chýba, systém spadne pekne.

## `tests/unit/test_missing_bridge_rule.py`

```python
from socfw.validate.rules.bridge_rules import MissingBridgeRule


def test_missing_bridge_rule(system_with_unbridgeable_peripheral, registry_without_wb_bridge):
    diags = MissingBridgeRule(registry_without_wb_bridge).validate(system_with_unbridgeable_peripheral)
    assert any(d.code == "BRG001" for d in diags)
```

---

# 15. Čo týmto uzatváraš

Po tomto kroku už máš naozaj silný dôkaz, že framework je:

* protokolovo rozšíriteľný
* bridge-driven
* planner-driven
* nie hardcoded na jeden bus

A to bol jeden z tvojich hlavných cieľov od začiatku.

---

# 16. Môj stručný verdikt k celému návrhu

Architektonicky už máš veľmi dobrý základ:

* typed configs
* validation
* elaboration
* IR
* emitters
* reports
* firmware flow
* IRQ runtime
* bridge registry

To je už moderný framework.

Teraz by som ďalšie kroky delil skôr podľa priority produktu než architektúry.

---

# 17. Čo by som robil ďalej

Najlepšie tri smery sú:

### A

**schema export + docs generation**

* auto-generované referencie YAML schém
* lepšia onboarding dokumentácia

### B

**vendor IP cleanup**

* Quartus IP import contract
* qip/qsys wrappers
* shared board/project packaging

### C

**performance / scale hardening**

* cache
* incremental build
* richer diagnostics

Môj praktický odporúčaný ďalší krok je:

👉 **A — schema export + auto docs generation**

Lebo architektúra už stojí. Teraz je veľmi dobré spraviť framework zrozumiteľný aj pre ďalšieho človeka v tíme.

Ak chceš, ďalšia správa môže byť presne:
**schema export + auto-generated config reference docs + example catalog layout**
