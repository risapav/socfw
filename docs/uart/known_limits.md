# UART Library — Known Limits (v1.0)

---

## IRQ[0] and IRQ[1] are level-latched, not edge-triggered

`IRQ_STATUS[0]` (rx_not_empty) and `IRQ_STATUS[1]` (tx_not_full) are
level-latched sources. After clearing them with W1C, they re-assert in the
next clock cycle if the underlying condition still holds:
- `[0]` re-asserts if RX FIFO is still non-empty.
- `[1]` re-asserts if TX FIFO is still not full.

This means a simple "clear all pending IRQs once" loop in an ISR may see
these bits set again immediately. The correct pattern is:

```c
// Drain the condition first, then clear the IRQ bit.
while (uart_read(STATUS) & (1 << UART_STATUS_RX_VALID))
    process(uart_read(RX_DATA) & 0xFF);
uart_write(IRQ_STATUS, (1 << UART_IRQ_RX_NOT_EMPTY));
```

Planned fix: add `IRQ_RAW_STATUS` (live level) and make `IRQ_STATUS` purely
edge/sticky in a future version.

---

## TX write to full FIFO: byte dropped, BRESP=OKAY

Writing to TX_DATA (0x20) when the TX FIFO is full silently drops the byte.
The AXI-Lite write response is OKAY (no SLVERR). The event is recorded in:
- `ERROR_STATUS[3]` (tx_write_full, sticky, W1C)
- `IRQ_STATUS[5]` (tx_write_when_full, cleared by ERROR_STATUS[3] W1C)

Software must check `STATUS[7]` (tx_ready) before writing to guarantee the
byte is accepted. There is no AXI-Lite backpressure mechanism in v1.0.

---

## Baud rate not runtime-configurable

`CLK_FREQ_HZ` and `BAUD_RATE` are synthesis-time parameters.
`BAUD_DIV_TX` and `BAUD_DIV_RX` registers are read-only.
Runtime baud reconfiguration requires re-synthesis. Planned for v2.0.

---

## CONF register not writable at runtime

`CONF` (parity, stop bits, data bits) is set by synthesis parameters and
read-only at runtime. Changing UART framing requires re-synthesis.

---

## No formal verification

The design has been validated by simulation and hardware loopback tests.
Formal property verification (SVA / bounded model checking) has not been
applied in v1.0. Planned for a future version.

---

## No RTS/CTS flow control

Hardware flow control is not implemented. Overflow protection relies on
software polling or IRQ-driven drain of the RX FIFO before overrun occurs.
At 115200 baud and FIFO_DEPTH=64: ~5.5 ms before overrun.

---

## uart_test_05_axil not a standalone release package

`examples/uart_test_05_axil` references RTL via relative paths
(`../../rtl/uart/`, `../../rtl/axi/`). The project works in the monorepo
but is not self-contained as a ZIP. A standalone release package is deferred.
