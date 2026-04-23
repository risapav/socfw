#ifndef ISR_H
#define ISR_H

#include <stdint.h>

typedef void (*isr_fn_t)(void);

void isr_init(void);
void isr_register(unsigned irq_id, isr_fn_t fn);
void irq_handler(void);

#endif
