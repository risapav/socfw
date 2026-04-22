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
