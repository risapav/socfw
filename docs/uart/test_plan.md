# UART Library — Test Plan

---

## Simulation Testbenches

### tb_uart_axil (uart_test_04/sim/unit/)

AXI-Lite register interface unit tests.

| Test | Description                                           | Coverage               |
|------|-------------------------------------------------------|------------------------|
| T01  | Read ID, VERSION, BAUD_DIV_TX/RX, CONF               | Reset state, RO regs   |
| T02  | Read STATUS after reset (tx_ready=1, rx_valid=0, ...)| Reset STATUS           |
| T03  | Write 0x55 to TX_DATA, poll rx_valid via STATUS       | TX/RX FIFO loopback    |
| T04  | Read RX_DATA: valid=1, data=0x55, rx_valid clears    | FIFO pop on read       |
| T05  | IRQ_ENABLE, IRQ_STATUS W1C, irq_o assertion          | IRQ path               |
| T06  | Fill TX FIFO, write one more → ERROR_STATUS[3] set;  | TX full detection,     |
|      | IRQ_STATUS[5] cascade; ERROR W1C clears IRQ          | ERROR→IRQ cascade      |
| T07  | TX_DATA write with WSTRB[0]=0 must not push byte     | WSTRB gate             |
| T08  | Read RX_DATA when FIFO empty → valid=0, no FIFO pop  | Empty RX read          |
| T09  | Write 3 bytes, check FIFO_LEVEL, read back, verify   | FIFO_LEVEL tracking    |

**Total: 41 assertions, 0 FAIL**

---

### tb_uart_core_rx_os (uart_test_04/sim/unit/)

RX oversampled core unit tests.

| Test | Description                                    |
|------|------------------------------------------------|
| R01  | Normal receive 0x55                            |
| R02  | Burst receive 0xAA, 0x55                       |
| R03  | Glitch < 1 OS tick ignored                    |
| R04  | Short stop bit → frame_err                     |
| R05  | Single-sample glitch on data bit: majority wins|
| R06  | Burst 8 bytes: 0x00, 0xFF, 0xAA, 0x55, ...    |

**Total: 18 assertions, 0 FAIL**

---

### tb_uart_fifo_loopback_os (uart_test_04/sim/integration/)

FIFO + OS-RX integration: TX→RX loopback via `uart_fifo_os`.

- 512 LFSR bytes, chunk sizes from 1 to 512.
- Verifies stop-bit detection, byte integrity, FIFO level tracking.

**Total: 512 PASS**

---

### tb_uart_test_05_axil_top (uart_test_05_axil/sim/)

Top-level integration: `soc_top` with `uart_axil` + `axil_uart_loopback`.

- Tests T01–T04 (register sanity, 512-byte LFSR loopback).
- All 1186 assertions PASS.

---

## Hardware Validation

### uart_test_04 — FIFO/OS-RX

| Test                          | Count   | Result     |
|-------------------------------|---------|------------|
| Loopback sweep cs=1..64       | 40 runs | 40/40 PASS |
| Fmax (Slow 85C)               | —       | 141.08 MHz |

### uart_test_05_axil — AXI-Lite peripheral

| Test                                     | Count        | Result      |
|------------------------------------------|--------------|-------------|
| Quick smoke (8B)                         | 8 bytes      | PASS        |
| Bulk loopback (256B)                     | 256 bytes    | PASS        |
| Soak: sweep cs=1,8,16,24,25,26,32,64     | 1024B each   | 8/8 cs PASS |
| Soak: cs=64, 4096B, repeat 10            | 40960 bytes  | 10/10 PASS  |
| Fmax (Slow 85C)                          | —            | ~140.3 MHz  |

---

## Known Limits (see known_limits.md)

- IRQ[0] and IRQ[1] are level-latched (re-assert after W1C if condition persists).
- TX write to full FIFO: byte dropped silently (BRESP=OKAY); ERROR_STATUS[3] set.
- BAUD_DIV computed at synthesis (not runtime-configurable in v1.0).
