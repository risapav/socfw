# IRQ Model

## Peripheral IRQ sources

Peripherals declare IRQ outputs in their IP descriptor:

```yaml
irqs:
  - name: changed
    id: 0
```

The framework generates `irq_{instance}_{name}` wires connecting peripheral outputs to the IRQ controller.

## IRQ controller (`irq_ctrl`)

When a project includes an `irq_ctrl` module, it handles:
- `pending` register (ro): latches all IRQ sources
- `enable` register (rw): masks individual IRQs
- `ack` register (wo): clears pending bits

The controller outputs `cpu_irq_o = pending & enable` to the CPU.

RTL builder wires:
- `irq_vector[n] = irq_{instance}_{name}` for each source
- `irq0.src_irq_i = irq_vector`
- `cpu0.irq = cpu_irq`

## CPU IRQ ABI

The CPU descriptor specifies the IRQ ABI:

```yaml
irq_abi:
  kind: wrapper_minimal
  irq_entry_addr: 0x10
  enable_mechanism: wrapper_hook
  return_instruction: reti
```

For PicoRV32 with `PROGADDR_IRQ=0x10`, the linker places `.text.irq` at `0x10`.

## ISR dispatch runtime

```c
// isr.h
typedef void (*isr_fn_t)(void);
void isr_init(void);
void isr_register(unsigned irq_id, isr_fn_t fn);
void irq_handler(void);  // called from start.S IRQ entry

// isr.c
static isr_fn_t isr_table[32];
void irq_handler(void) {
    uint32_t pending = *PENDING_REG & *ENABLE_REG;
    for (int i = 0; i < 32; i++) {
        if ((pending >> i) & 1) {
            if (isr_table[i]) isr_table[i]();
            *ACK_REG = (1u << i);
        }
    }
}
```

## IRQ combiner fallback

Systems without `irq_ctrl` use `RtlIrqBuilder` to generate an `irq_combiner.sv` instance that ORs all IRQ sources and connects to the CPU.
