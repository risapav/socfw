# uart_axil — Integration Guide

---

## Instantiation

```systemverilog
import axi_pkg::*;
import uart_pkg::*;

axi4lite_if #(.ADDR_WIDTH(8), .DATA_WIDTH(32)) uart_bus ();

uart_axil #(
  .CLK_FREQ_HZ    (125_000_000),
  .BAUD_RATE      (115200),
  .STOP2          (1'b0),
  .PARITY         (2'b00),    // None
  .DBITS          (2'b00),    // 8 bits
  .RX_FIFO_DEPTH  (64),
  .TX_FIFO_DEPTH  (64),
  .RX_FIFO_RAM_STYLE ("logic"),
  .TX_FIFO_RAM_STYLE ("logic")
) u_uart (
  .clk_i   (clk),
  .rst_ni  (rst_n),
  .s_axil  (uart_bus.slave),
  .rx_i    (uart_rx_pin),
  .tx_o    (uart_tx_pin),
  .irq_o   (uart_irq)
);
```

---

## Parameters

| Parameter          | Type   | Default    | Description                         |
|--------------------|--------|------------|-------------------------------------|
| CLK_FREQ_HZ        | int    | 125000000  | System clock frequency in Hz        |
| BAUD_RATE          | int    | 115200     | UART baud rate                      |
| STOP2              | bit    | 0          | 0=1 stop, 1=2 stop bits             |
| PARITY             | logic[1:0]| 2'b00   | 00=None, 01=Odd, 10=Even           |
| DBITS              | logic[1:0]| 2'b00   | 00=8, 01=7, 10=6, 11=5             |
| RX_FIFO_DEPTH      | int    | 64         | RX FIFO depth (power of 2)          |
| TX_FIFO_DEPTH      | int    | 64         | TX FIFO depth (power of 2)          |
| RX_FIFO_RAM_STYLE  | string | "logic"    | "logic" or "M9K"                    |
| TX_FIFO_RAM_STYLE  | string | "logic"    | "logic" or "M9K"                    |

---

## Ports

| Port    | Direction | Width | Description                      |
|---------|-----------|-------|----------------------------------|
| clk_i   | input     | 1     | System clock                     |
| rst_ni  | input     | 1     | Async reset, active-low           |
| s_axil  | slave     | —     | AXI-Lite slave interface          |
| rx_i    | input     | 1     | UART RX pin                      |
| tx_o    | output    | 1     | UART TX pin                      |
| irq_o   | output    | 1     | Interrupt (any enabled IRQ set)   |

---

## AXI-Lite Timing

- ARREADY, AWREADY, WREADY are **always 1** when the slave is not actively processing a response. Typically 1 cycle latency.
- RVALID is returned 1 cycle after the AR handshake.
- BVALID is returned 1 cycle after the W handshake.
- Minimum read latency: 2 cycles (AR + R).
- Minimum write latency: 3 cycles (AW+W combined, then B).

---

## Typical Software Flow (polling)

```c
// Wait for RX byte
while (!(uart_read(STATUS) & (1 << UART_STATUS_RX_VALID)));
uint32_t rx = uart_read(RX_DATA);
uint8_t byte = rx & 0xFF;
// rx[8] is always 1 here (checked rx_valid above)

// Send TX byte (non-blocking)
if (uart_read(STATUS) & (1 << UART_STATUS_TX_READY)) {
    uart_write(TX_DATA, byte);
}

// IRQ handler (interrupt driven)
void uart_irq_handler(void) {
    uint32_t pending = uart_read(IRQ_STATUS);
    if (pending & (1 << UART_IRQ_RX_NOT_EMPTY)) {
        // drain RX FIFO
        while (uart_read(STATUS) & (1 << UART_STATUS_RX_VALID)) {
            process_byte(uart_read(RX_DATA) & 0xFF);
        }
        uart_write(IRQ_STATUS, (1 << UART_IRQ_RX_NOT_EMPTY));
    }
    if (pending & ((1 << UART_IRQ_FRAME_ERR) | (1 << UART_IRQ_PARITY_ERR) |
                   (1 << UART_IRQ_OVERRUN_ERR))) {
        uint32_t err = uart_read(ERROR_STATUS);
        handle_error(err);
        uart_write(ERROR_STATUS, err);  // W1C clears both ERROR and IRQ bits
    }
}
```

---

## FIFO Depth Selection

- For 115200 baud at 125 MHz: one byte takes ~1085 cycles to transmit.
- A depth-64 FIFO holds 64 bytes = ~69 ms of TX data before overflow.
- Use `"logic"` RAM style for depths ≤ 64 (0 M9K blocks, minimal routing).
- Use `"M9K"` for depths ≥ 256 (saves LEs, uses embedded memory).

---

## IP Definition

The module is described as a reusable IP in `rtl/uart/ip/uart_axil.ip.yaml`.
Use this file with `socfw` to include `uart_axil` in a project.
