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
