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
