#include <stdint.h>

volatile uint32_t g_irq_count = 0;

void irq_entry(void) {
    g_irq_count++;
}
