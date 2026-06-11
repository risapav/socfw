/**
 * @file    uart_regs.h
 * @brief   uart_axil register offsets and bit indices for C/C++ software.
 * @details
 *  Generated from rtl/uart/uart_pkg.sv -- keep in sync with ABI version.
 *  ABI version: 0x0001_0500 (major=1, minor=5, patch=0)
 *
 *  Usage:
 *    uint32_t status = UART_RD(base, UART_REG_STATUS);
 *    if (status & (1u << UART_STATUS_RX_VALID)) {
 *        uint32_t rxd = UART_RD(base, UART_REG_RX_DATA);
 *        uint8_t byte = rxd & 0xFF;
 *    }
 */

#ifndef UART_REGS_H
#define UART_REGS_H

#include <stdint.h>

/* =========================================================================
 * Register offsets (AXI-Lite byte addresses)
 * ========================================================================= */
#define UART_REG_ID             0x00u
#define UART_REG_VERSION        0x04u
#define UART_REG_BAUD_DIV_TX    0x08u
#define UART_REG_BAUD_DIV_RX    0x0Cu
#define UART_REG_CONF           0x10u
#define UART_REG_STATUS         0x14u
#define UART_REG_FIFO_LEVEL     0x18u
#define UART_REG_RX_DATA        0x1Cu
#define UART_REG_TX_DATA        0x20u
#define UART_REG_IRQ_ENABLE     0x24u
#define UART_REG_IRQ_STATUS     0x28u
#define UART_REG_ERROR_STATUS   0x2Cu

/* =========================================================================
 * ID register expected value
 * ========================================================================= */
#define UART_ID_VALUE           0x55415254u  /* "UART" */

/* =========================================================================
 * STATUS register bit indices (UART_REG_STATUS, 0x14)
 * ========================================================================= */
#define UART_STATUS_TX_BUSY         0   /* TX core transmitting */
#define UART_STATUS_RX_BUSY         1   /* RX core receiving */
#define UART_STATUS_TX_FIFO_EMPTY   2
#define UART_STATUS_TX_FIFO_FULL    3
#define UART_STATUS_RX_FIFO_EMPTY   4
#define UART_STATUS_RX_FIFO_FULL    5
#define UART_STATUS_RX_VALID        6   /* RX FIFO non-empty */
#define UART_STATUS_TX_READY        7   /* TX FIFO not full */

#define UART_STATUS_TX_BUSY_M       (1u << UART_STATUS_TX_BUSY)
#define UART_STATUS_RX_BUSY_M       (1u << UART_STATUS_RX_BUSY)
#define UART_STATUS_TX_FIFO_EMPTY_M (1u << UART_STATUS_TX_FIFO_EMPTY)
#define UART_STATUS_TX_FIFO_FULL_M  (1u << UART_STATUS_TX_FIFO_FULL)
#define UART_STATUS_RX_FIFO_EMPTY_M (1u << UART_STATUS_RX_FIFO_EMPTY)
#define UART_STATUS_RX_FIFO_FULL_M  (1u << UART_STATUS_RX_FIFO_FULL)
#define UART_STATUS_RX_VALID_M      (1u << UART_STATUS_RX_VALID)
#define UART_STATUS_TX_READY_M      (1u << UART_STATUS_TX_READY)

/* =========================================================================
 * FIFO_LEVEL register fields (UART_REG_FIFO_LEVEL, 0x18)
 * ========================================================================= */
#define UART_FIFO_TX_LEVEL(reg)     ((uint32_t)(reg) & 0xFFFu)
#define UART_FIFO_RX_LEVEL(reg)     (((uint32_t)(reg) >> 12) & 0xFFFu)

/* =========================================================================
 * RX_DATA register fields (UART_REG_RX_DATA, 0x1C)
 *   Read pops one entry from RX FIFO.
 *   Reading when empty: valid=0, data=0, no FIFO effect.
 * ========================================================================= */
#define UART_RX_DATA_BYTE(reg)      ((uint8_t)((reg) & 0xFFu))
#define UART_RX_DATA_VALID(reg)     (((reg) >> 8) & 1u)

/* =========================================================================
 * CONF register fields (UART_REG_CONF, 0x10)
 * ========================================================================= */
#define UART_CONF_DBITS(reg)        ((reg) & 0x3u)
#define UART_CONF_PARITY(reg)       (((reg) >> 2) & 0x3u)
#define UART_CONF_STOP2(reg)        (((reg) >> 4) & 0x1u)

/* =========================================================================
 * IRQ bit indices (UART_REG_IRQ_ENABLE / IRQ_STATUS, 0x24 / 0x28)
 *   [0] and [1] are level-latched: re-assert if condition persists after W1C.
 *   [2..5] are sticky: cleared by W1C only.
 * ========================================================================= */
#define UART_IRQ_RX_NOT_EMPTY           0
#define UART_IRQ_TX_NOT_FULL            1
#define UART_IRQ_FRAME_ERR              2
#define UART_IRQ_PARITY_ERR             3
#define UART_IRQ_OVERRUN_ERR            4
#define UART_IRQ_TX_WRITE_WHEN_FULL     5

#define UART_IRQ_RX_NOT_EMPTY_M         (1u << UART_IRQ_RX_NOT_EMPTY)
#define UART_IRQ_TX_NOT_FULL_M          (1u << UART_IRQ_TX_NOT_FULL)
#define UART_IRQ_FRAME_ERR_M            (1u << UART_IRQ_FRAME_ERR)
#define UART_IRQ_PARITY_ERR_M           (1u << UART_IRQ_PARITY_ERR)
#define UART_IRQ_OVERRUN_ERR_M          (1u << UART_IRQ_OVERRUN_ERR)
#define UART_IRQ_TX_WRITE_WHEN_FULL_M   (1u << UART_IRQ_TX_WRITE_WHEN_FULL)

/* =========================================================================
 * ERROR_STATUS bit indices (UART_REG_ERROR_STATUS, 0x2C, W1C)
 *   Clearing ERROR[n] also clears the corresponding IRQ_STATUS bit.
 * ========================================================================= */
#define UART_ERR_OVERRUN            0   /* -> IRQ[4] */
#define UART_ERR_FRAME              1   /* -> IRQ[2] */
#define UART_ERR_PARITY             2   /* -> IRQ[3] */
#define UART_ERR_TX_WRITE_FULL      3   /* -> IRQ[5] */

#define UART_ERR_OVERRUN_M          (1u << UART_ERR_OVERRUN)
#define UART_ERR_FRAME_M            (1u << UART_ERR_FRAME)
#define UART_ERR_PARITY_M           (1u << UART_ERR_PARITY)
#define UART_ERR_TX_WRITE_FULL_M    (1u << UART_ERR_TX_WRITE_FULL)

/* =========================================================================
 * Register access helpers (adapt to your platform's MMIO primitives)
 * ========================================================================= */
#ifndef UART_RD
#define UART_RD(base, reg)          (*(volatile uint32_t *)((uintptr_t)(base) + (reg)))
#endif
#ifndef UART_WR
#define UART_WR(base, reg, val)     (*(volatile uint32_t *)((uintptr_t)(base) + (reg)) = (val))
#endif

#endif /* UART_REGS_H */
