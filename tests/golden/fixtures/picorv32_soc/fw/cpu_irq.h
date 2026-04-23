#ifndef CPU_IRQ_H
#define CPU_IRQ_H

static inline void cpu_enable_irqs(void) {
    /* Wrapper-defined hook for current PicoRV32 integration slice.
       Replace with verified native enable sequence once finalized. */
    __asm__ volatile ("" ::: "memory");
}

#endif
