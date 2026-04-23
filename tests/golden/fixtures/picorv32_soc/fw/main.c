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
