/* AUTO-GENERATED - DO NOT EDIT */

#ifndef SOC_MAP_H
#define SOC_MAP_H

#include <stdint.h>

#define SYS_CLK_HZ       50000000UL
#define RAM_BASE         0x00000000UL
#define RAM_SIZE_BYTES   65536U
#define RESET_VECTOR     0x00000000UL
#define STACK_SIZE_BYTES (65536U * 25U / 100U)

/* ram @ 0x00000000 (soc_ram) */
#define RAM_BASE 0x00000000UL

/* gpio0 @ 0x40000000 (gpio) */
#define GPIO0_BASE 0x40000000UL

#define GPIO0_VALUE_REG (*((volatile uint32_t*)(0x40000000UL)))  /* rw  GPIO output value */
#define GPIO0_IRQ_PENDING_REG (*((volatile uint32_t*)(0x40000004UL)))  /* rw  IRQ pending flag */

#endif /* SOC_MAP_H */
