Perfektné — toto je jeden z najdôležitejších krokov pre „dospelosť“ frameworku.

Ideme na:

# 🚀 **status/command register contract**

(t.j. register behavior model, nie len storage)

Po tomto kroku budeš vedieť generovať periférie, ktoré majú:

* ✅ command registre (write pulse)
* ✅ sticky status bity
* ✅ clear-on-write flagy
* ✅ hardware-driven status (RO)
* ✅ IRQ pending logiku

To je presne to, čo robí rozdiel medzi „toy generatorom“ a reálnym SoC frameworkom.

---

# 1. Rozšírenie register metadata (IP YAML)

Pridáme behavior flags.

## update `socfw/config/ip_schema.py`

```python
class IpRegisterSchema(BaseModel):
    name: str
    offset: int
    width: int = 32
    access: str = "rw"
    reset: int = 0
    desc: str = ""

    # nové:
    hw_source: str | None = None
    write_pulse: bool = False
    clear_on_write: bool = False
    set_by_hw: bool = False
    sticky: bool = False
```

---

# 2. IR rozšírenie

## update `socfw/ir/register_block.py`

```python
@dataclass(frozen=True)
class RegFieldIR:
    name: str
    offset: int
    width: int
    access: str
    reset: int
    desc: str
    word_addr: int

    hw_source: str | None = None
    write_pulse: bool = False

    clear_on_write: bool = False
    set_by_hw: bool = False
    sticky: bool = False
```

---

# 3. Builder update

## update `register_block_ir_builder.py`

```python
RegFieldIR(
    name=str(r["name"]),
    offset=int(r["offset"]),
    width=int(r.get("width", 32)),
    access=str(r.get("access", "rw")),
    reset=int(r.get("reset", 0)),
    desc=str(r.get("desc", "")),
    word_addr=int(r["offset"]) // 4,
    hw_source=r.get("hw_source"),
    write_pulse=bool(r.get("write_pulse", False)),
    clear_on_write=bool(r.get("clear_on_write", False)),
    set_by_hw=bool(r.get("set_by_hw", False)),
    sticky=bool(r.get("sticky", False)),
)
```

---

# 4. Nový regblock behavior (hlavný upgrade)

## update `socfw/templates/reg_block.sv.j2`

Toto je kľúčová časť.

### 🔧 nový write + HW update model

Nahraď write always_ff blok týmto:

```jinja2
always_ff @(posedge SYS_CLK or negedge RESET_N) begin
  if (!RESET_N) begin
{% for r in regblk.regs if r.access != "ro" -%}
    r_{{ r.name.lower() }} <= {{ r.width }}'h{{ "%X"|format(r.reset) }};
{% endfor %}
  end else begin

    // HW-driven set (sticky)
{% for r in regblk.regs if r.set_by_hw -%}
    if (hw_{{ r.name.lower() }})
      r_{{ r.name.lower() }} <= {{ r.width }}'h{{ "%X"|format((1 << r.width) - 1) }};
{% endfor %}

    // SW write
    if (valid_i && we_i) begin
      case (addr_i)
{% for r in regblk.regs if r.access in ["rw", "wo"] -%}
        {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: begin
{% if r.clear_on_write -%}
          r_{{ r.name.lower() }} <= r_{{ r.name.lower() }} & ~wdata_i[{{ r.width - 1 }}:0];
{% else -%}
          r_{{ r.name.lower() }} <= wdata_i[{{ r.width - 1 }}:0];
{% endif %}
        end
{% endfor %}
        default: ;
      endcase
    end

  end
end
```

---

### 🔧 write pulse (command register)

Zachovaj:

```jinja2
always_comb begin
{% for r in regblk.regs if r.write_pulse -%}
  reg_{{ r.name.lower() }}_we = 1'b0;
{% endfor %}
  if (valid_i && we_i) begin
    case (addr_i)
{% for r in regblk.regs if r.write_pulse -%}
      {{ regblk.addr_width }}'h{{ "%X"|format(r.word_addr) }}: reg_{{ r.name.lower() }}_we = 1'b1;
{% endfor %}
      default: ;
    endcase
  end
end
```

---

### 🔧 RO + HW status

Už máme:

```jinja2
hw_{{ r.name.lower() }}
```

---

# 5. Shell update pre HW signals

## update `peripheral_shell.sv.j2`

Doplň HW inputs:

```jinja2
{% for c in shell.core_conns if c.kind == "status" -%}
logic [31:0] {{ c.signal_name }};
{% endfor %}
```

A v `u_regs`:

```jinja2
{% for c in shell.core_conns if c.kind == "status" -%}
,
  .{{ c.signal_name }} ({{ c.signal_name }})
{% endfor %}
```

---

# 6. Prvý reálny príklad (GPIO + IRQ pending)

Teraz si ukážeme silu systému.

## update `gpio.ip.yaml`

```yaml
registers:
  - name: value
    offset: 0
    width: 32
    access: rw
    reset: 0

  - name: irq_pending
    offset: 4
    width: 1
    access: rw
    reset: 0
    set_by_hw: true
    clear_on_write: true
    desc: IRQ pending flag
```

---

## shell metadata

```yaml
shell:
  module: gpio_core

  external_ports:
    - name: gpio_o
      direction: output
      width: 6

  core_ports:
    - kind: reg
      reg_name: value
      port_name: reg_value

    - kind: status
      signal_name: irq_pending
      port_name: irq_pending

    - kind: irq
      signal_name: irq_changed
      port_name: irq_changed

    - kind: external
      signal_name: gpio_o
      port_name: gpio_o
```

---

## GPIO core update

```systemverilog
module gpio_core (
  input  wire        SYS_CLK,
  input  wire        RESET_N,
  input  wire [31:0] reg_value,
  output wire        irq_pending,
  output wire        irq_changed,
  output wire [5:0]  gpio_o
);

  logic [31:0] prev_value;

  always_ff @(posedge SYS_CLK or negedge RESET_N) begin
    if (!RESET_N)
      prev_value <= 32'h0;
    else
      prev_value <= reg_value;
  end

  assign gpio_o = reg_value[5:0];

  assign irq_changed = (reg_value != prev_value);

  // HW event → pending
  assign irq_pending = irq_changed;

endmodule
```

---

# 7. Čo sa teraz deje (dôležité pochopiť)

### HW event flow:

```
gpio_core → irq_pending (1)
        ↓
regblock.set_by_hw → r_irq_pending = 1
        ↓
CPU číta register → vidí IRQ pending
        ↓
CPU zapíše 1 → clear_on_write
        ↓
r_irq_pending = 0
```

🔥 Toto je presne behavior, ktorý chceš v každom SoC.

---

# 8. SW výsledok

`soc_map.h`:

```c
#define GPIO0_IRQ_PENDING_REG (*(volatile uint32_t*)(0x40000004))
```

---

# 9. Výsledok architektúry

Po tomto kroku máš:

### ✔️ plne generovaný control plane

* RW registre
* RO status
* command registre
* IRQ pending logika

### ✔️ čistý core

* bez bus
* bez register storage
* bez reset boilerplate

---

# 10. Čo by som spravil ďalej

Teraz máš extrémne silný základ.

Ďalšie 2 najlepšie kroky:

---

## 👉 A) CPU descriptor registry (odporúčam)

* CPU ako IP descriptor
* podpora:

  * RISC-V core
  * reset vector
  * memory map integration

---

## 👉 B) Bus abstraction layer (AXI-lite / Wishbone adapters)

* zachovať simple_bus ako IR
* generovať adapters

---

# 🔥 Môj odporúčaný ďalší krok

👉 **CPU descriptor registry + softcore integration**

Pretože:

* už máš SW mapy
* máš IRQ
* máš RAM
* chýba ti reálny CPU

---

Ak chceš, ďalšia správa bude:

👉 **CPU descriptor systém + prvý RISC-V softcore (napr. PicoRV32 / VexRiscv integrácia)**
