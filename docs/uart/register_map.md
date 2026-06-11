# uart_axil Register Map

**Module:** `uart_axil`  
**ABI version:** 0x0001_0500 (major=1, minor=5, patch=0)  
**Bus:** AXI-Lite slave, 8-bit address, 32-bit data  
**Single source of truth:** `rtl/uart/uart_pkg.sv`

---

## Register Table

| Offset | Name          | Access | Reset      | Description                                 |
|--------|---------------|--------|------------|---------------------------------------------|
| 0x00   | ID            | RO     | 0x55415254 | ASCII "UART"                                |
| 0x04   | VERSION       | RO     | 0x0001_0500| [31:24]=major, [23:16]=minor, [15:8]=patch  |
| 0x08   | BAUD_DIV_TX   | RO     | computed   | floor(CLK_FREQ_HZ / BAUD_RATE)             |
| 0x0C   | BAUD_DIV_RX   | RO     | computed   | floor(CLK_FREQ_HZ / (BAUD_RATE * 16))      |
| 0x10   | CONF          | RO     | 0x00       | [4]=stop2, [3:2]=parity, [1:0]=dbits        |
| 0x14   | STATUS        | RO     | 0x84       | See STATUS bits below                       |
| 0x18   | FIFO_LEVEL    | RO     | 0x00       | [23:12]=rx_level, [11:0]=tx_level           |
| 0x1C   | RX_DATA       | RO*    | 0x00       | [8]=valid, [7:0]=data; **READ POPS RX FIFO**|
| 0x20   | TX_DATA       | WO     | —          | [7:0]=data; write pushes TX FIFO            |
| 0x24   | IRQ_ENABLE    | RW     | 0x00       | [5:0] per-source enable mask                |
| 0x28   | IRQ_STATUS    | W1C    | 0x00       | [5:0] pending; write 1 to clear             |
| 0x2C   | ERROR_STATUS  | W1C    | 0x00       | [3:0] sticky errors; write 1 to clear       |

---

## STATUS Register (0x14)

| Bit | Name           | Description                    |
|-----|----------------|-------------------------------- |
| 7   | tx_ready       | TX FIFO not full (can accept write)|
| 6   | rx_valid       | RX FIFO not empty (data available)|
| 5   | rx_fifo_full   | RX FIFO full                   |
| 4   | rx_fifo_empty  | RX FIFO empty                  |
| 3   | tx_fifo_full   | TX FIFO full                   |
| 2   | tx_fifo_empty  | TX FIFO empty                  |
| 1   | rx_busy        | RX core receiving               |
| 0   | tx_busy        | TX core transmitting            |

---

## RX_DATA Register (0x1C)

| Bits | Description                         |
|------|-------------------------------------|
| [8]  | valid — 1 if data was present in FIFO|
| [7:0]| data byte                           |

**Important:** Every read of this register pops one entry from the RX FIFO.
Reading when empty returns valid=0 and data=0 with no side effect on the FIFO.

---

## TX_DATA Register (0x20)

| Bits | Description |
|------|-------------|
| [7:0]| data byte   |

Write pushes one byte into the TX FIFO. WSTRB[0] must be 1; writes with
WSTRB[0]=0 are silently ignored. If the TX FIFO is full, the byte is
**dropped** (AXI-Lite BRESP remains OKAY) and ERROR_STATUS[3] is set.

---

## IRQ_ENABLE / IRQ_STATUS (0x24 / 0x28)

| Bit | Name                  | Type         | Description                           |
|-----|-----------------------|--------------|---------------------------------------|
| 5   | tx_write_when_full    | sticky       | TX write dropped (FIFO was full)       |
| 4   | overrun_err           | sticky       | RX overrun                            |
| 3   | parity_err            | sticky       | Parity error                          |
| 2   | frame_err             | sticky       | Frame error (stop bit wrong)          |
| 1   | tx_not_full           | level-latched| TX FIFO not full                      |
| 0   | rx_not_empty          | level-latched| RX FIFO not empty                     |

`irq_o` is asserted when any `(IRQ_STATUS & IRQ_ENABLE) != 0`.

**Level-latched bits [0] and [1]:** After W1C clear, these bits re-assert
in the next clock cycle if the condition still holds (RX FIFO still non-empty
or TX FIFO still not full). They are NOT single-cycle edge events.

**Sticky bits [2:5]:** Remain set until explicitly cleared by W1C.

---

## ERROR_STATUS (0x2C)

| Bit | Name              | Clears IRQ bit | Description                      |
|-----|-------------------|----------------|----------------------------------|
| 3   | tx_write_full     | IRQ[5]         | TX write dropped (FIFO full)     |
| 2   | parity_err        | IRQ[3]         | Parity error detected            |
| 1   | frame_err         | IRQ[2]         | Frame error detected             |
| 0   | overrun_err       | IRQ[4]         | RX overrun (byte lost)           |

Writing 1 to any bit clears it and also clears the corresponding IRQ_STATUS bit.

---

## CONF Register (0x10)

| Bits  | Name   | Value                              |
|-------|--------|------------------------------------|
| [1:0] | dbits  | 00=8, 01=7, 10=6, 11=5 data bits   |
| [3:2] | parity | 00=None, 01=Odd, 10=Even           |
| [4]   | stop2  | 0=1 stop bit, 1=2 stop bits        |

Set at synthesis via parameters; read-only at runtime.
