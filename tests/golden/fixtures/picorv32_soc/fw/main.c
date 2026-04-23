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
