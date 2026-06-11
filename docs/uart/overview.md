# UART Library — Overview

**Version:** 1.0  
**Target:** Intel Cyclone IV E (QMTech EP4CE55), Quartus Prime 25.1 Lite  
**Language:** SystemVerilog  
**Status:** uart_lib_v1_0

---

## Module Hierarchy

```
uart_pkg.sv          -- ABI constants, types, helpers (package)

uart_baud_gen.sv     -- Baud rate divider (TX clock, 16x OS clock)

uart_core_tx.sv      -- UART TX shift register (bare, no FIFO)
uart_core_rx.sv      -- UART RX shift register (bare, no oversampling)
uart_core_rx_os.sv   -- UART RX shift register (16x oversampled, majority vote)

uart.sv              -- uart_core_tx + uart_core_rx, single-byte interface
uart_os.sv           -- uart_core_tx + uart_core_rx_os, single-byte interface

sync_fifo.sv         -- Generic synchronous FIFO
uart_fifo.sv         -- uart (non-OS) + RX/TX FIFOs
uart_fifo_os.sv      -- uart_os (OS-RX) + RX/TX FIFOs

uart_axil.sv         -- AXI-Lite peripheral wrapping uart_fifo_os
```

For production use, instantiate **`uart_axil`** (AXI-Lite) or **`uart_fifo_os`** (AXI-Stream-like).

---

## Key Design Choices

- **16x oversampled RX** (`uart_core_rx_os`) with majority vote on samples 6/7/8 — robust against single-sample glitches, no phase alignment required.
- **PRESCALE_RX_OS = floor(CLK / (BAUD * 16))** — floor (not round) matches hardware prescaler behavior; confirmed correct for 125 MHz / 115200.
- **FIFO in logic (M9K=0)** — both RX and TX FIFOs use distributed logic, verified on Cyclone IV E.
- **AXI-Lite peripheral** — `uart_axil` exposes 12 registers at 0x00–0x2C; slave handshake is single-cycle (ARREADY/AWREADY/WREADY always 1 when idle).

---

## Resource Usage (uart_axil, Cyclone IV E, 125 MHz)

| Metric          | Value        |
|-----------------|--------------|
| LEs             | 1,674        |
| Registers       | 1,254        |
| Memory bits     | 0 (logic FIFO)|
| Fmax (85C slow) | ~140.3 MHz   |
| Setup slack     | +0.550 ns    |

---

## Simulation Coverage

| Testbench                      | Tests | Result |
|-------------------------------|-------|--------|
| tb_uart_axil                  | 41    | PASS   |
| tb_uart_core_rx_os             | 18    | PASS   |
| tb_uart_fifo_loopback_os       | 512   | PASS   |
| tb_uart_test_05_axil_top       | 1186  | PASS   |

---

## HW Validation (QMTech EP4CE55)

| Project          | Test                                     | Result      |
|-----------------|------------------------------------------|-------------|
| uart_test_04    | Loopback cs=1..64 (40 runs)              | 40/40 PASS  |
| uart_test_05_axil | Loopback 256B bulk                      | 256/256 PASS|
| uart_test_05_axil | Soak: cs=1,8,16,24,25,26,32,64 x1024B  | 8/8 cs PASS |
| uart_test_05_axil | Soak: cs=64 x4096B x10 repeats         | 10/10 PASS  |
