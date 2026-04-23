#define AXIGPIO0_VALUE_REG (*(volatile unsigned *)(0x40002000u))

static void delay(volatile unsigned count) {
    while (count--)
        __asm__ volatile("nop");
}

int main(void) {
    while (1) {
        AXIGPIO0_VALUE_REG = 0x15;
        delay(200000);
        AXIGPIO0_VALUE_REG = 0x2A;
        delay(200000);
    }
    return 0;
}
