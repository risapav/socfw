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
