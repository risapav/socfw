Nižšie je AC608 prepísaná do našej syntaxe.

```yaml
version: 2
kind: board

board:
  id: ac608_ep4ce15
  vendor: AC608
  title: AC608 Cyclone IV E EP4CE15E22C8

fpga:
  family: "Cyclone IV E"
  part: EP4CE15E22C8
  package: TQFP
  pins: 144
  speed: 8
  hdl_default: SystemVerilog_2005

system:
  clock:
    id: sys_clk
    top_name: clk
    pin: E15
    io_standard: "3.3-V LVTTL"
    frequency_hz: 50000000
    period_ns: 20.0

resources:
  onboard:
    leds:
      kind: vector
      top_name: ONB_LEDS
      direction: output
      width: 5
      io_standard: "3.3-V LVTTL"
      pins: [L3, J13, G16, B16, F8]

    buttons:
      kind: vector
      top_name: ONB_BUTTON
      direction: input
      width: 3
      io_standard: "3.3-V LVTTL"
      pins: [E1, B8, A8]

    uart:
      rx:
        kind: scalar
        top_name: UART_RX
        direction: input
        io_standard: "3.3-V LVTTL"
        pin: T13
      tx:
        kind: scalar
        top_name: UART_TX
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: R14

    i2c:
      sda:
        kind: inout
        top_name: I2C_SDA
        direction: inout
        io_standard: "3.3-V LVTTL"
        pin: C9
      scl:
        kind: scalar
        top_name: I2C_SCL
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: D9

    hdmi:
      tmds_p:
        kind: vector
        top_name: TMDS_P
        direction: output
        width: 4
        io_standard: "LVDS_E_3R"
        pins: [L2, N2, P2, K2]
      tmds_n:
        kind: vector
        top_name: TMDS_N
        direction: output
        width: 4
        io_standard: "LVDS_E_3R"
        pins: [L1, N1, P1, K1]

  external:
    sdram:
      clk:
        kind: scalar
        top_name: SDRAM_CLK
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: A7
      cke:
        kind: scalar
        top_name: SDRAM_CKE
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: B7
      cs_n:
        kind: scalar
        top_name: SDRAM_CS_N
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: E7
      ras_n:
        kind: scalar
        top_name: SDRAM_RAS_N
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: C8
      cas_n:
        kind: scalar
        top_name: SDRAM_CAS_N
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: D8
      we_n:
        kind: scalar
        top_name: SDRAM_WE_N
        direction: output
        io_standard: "3.3-V LVTTL"
        pin: E8

      dq:
        kind: inout
        top_name: SDRAM_DQ
        direction: inout
        width: 16
        io_standard: "3.3-V LVTTL"
        pins: [D14, C14, D12, B13, E10, B12, D11, C11, B10, A11, B11, A12, A13, A14, B14, A15]

      addr:
        kind: vector
        top_name: SDRAM_ADDR
        direction: output
        width: 12
        io_standard: "3.3-V LVTTL"
        pins: [D5, C3, D3, A2, B3, A3, B4, A4, B5, A5, E6, B6]

      ba:
        kind: vector
        top_name: SDRAM_BA
        direction: output
        width: 2
        io_standard: "3.3-V LVTTL"
        pins: [C6, D6]

      dqm:
        kind: vector
        top_name: SDRAM_DQM
        direction: output
        width: 2
        io_standard: "3.3-V LVTTL"
        pins: [E9, A10]

    headers:
      P8:
        gpio:
          kind: inout
          top_name: HDR_P8_D
          direction: inout
          width: 14
          io_standard: "3.3-V LVTTL"
          pins: [R1, T2, R3, T3, T9, R4, T4, R5, T5, R6, T6, R7, T7, R10]

      P5:
        gpio:
          kind: inout
          top_name: HDR_P5_D
          direction: inout
          width: 2
          io_standard: "3.3-V LVTTL"
          pins: [A9, B9]

      P6:
        gpio:
          kind: inout
          top_name: HDR_P6_D
          direction: inout
          width: 2
          io_standard: "3.3-V LVTTL"
          pins: [M16, M15]
```

Dôležité: mapy typu:

```yaml
4: F8
3: B16
...
0: L3
```

som preložil na list v poradí bitov:

```yaml
pins: [bit0, bit1, bit2, ...]
```

Čiže LED pôvodne:

```yaml
4: F8
3: B16
2: G16
1: J13
0: L3
```

sa zmení na:

```yaml
pins: [L3, J13, G16, B16, F8]
```

## Project YAML použitie

Pre LED blink na AC608:

```yaml
version: 2
kind: project

project:
  name: ac608_blink
  mode: standalone
  board: ac608_ep4ce15
  board_file: boards/ac608_ep4ce15.yaml
  debug: true

registries:
  packs: []
  ip:
    - ip
  cpu: []

clocks:
  primary:
    domain: sys_clk
    source: board:sys_clk
    frequency_hz: 50000000
  generated: []

features:
  use:
    - board:onboard.leds

modules:
  - instance: blink0
    type: blink_test
    clocks:
      SYS_CLK: sys_clk
    params:
      CLK_FREQ: 50000000
    bind:
      ports:
        ONB_LEDS:
          target: board:onboard.leds
```

Pre HDMI výstup:

```yaml
features:
  use:
    - board:onboard.hdmi.tmds_p
    - board:onboard.hdmi.tmds_n

modules:
  - instance: hdmi0
    type: hdmi_out
    clocks:
      PIXEL_CLK: sys_clk
    bind:
      ports:
        TMDS_P:
          target: board:onboard.hdmi.tmds_p
        TMDS_N:
          target: board:onboard.hdmi.tmds_n
```

Pre SDRAM:

```yaml
features:
  use:
    - board:external.sdram
```

A bindy napríklad:

```yaml
bind:
  ports:
    zs_addr:
      target: board:external.sdram.addr
    zs_dq:
      target: board:external.sdram.dq
    zs_clk:
      target: board:external.sdram.clk
```

## Pokračovanie commitov

### Commit 62

```text
board: add AC608 Cyclone IV E board descriptor
```

Obsah:

```text
packs/builtin/boards/ac608_ep4ce15/board.yaml
tests/unit/test_ac608_board_loads.py
tests/integration/test_validate_ac608_blink.py
```

### Commit 63

```text
examples: add AC608 blink and HDMI skeleton projects
```

Obsah:

```text
examples/ac608_blink/project.yaml
examples/ac608_hdmi_out/project.yaml
```

### Commit 64

```text
validate: add board pin map normalization for indexed pin dictionaries
```

Cieľ: automaticky prijať aj:

```yaml
pins:
  4: F8
  0: L3
```

a normalizovať na:

```yaml
pins: [L3, ..., F8]
```

### Commit 65

```text
validate: add pin conflict detection for selected board features
```

Cieľ: zachytiť, keď projekt naraz použije dve features na rovnakých pinoch.

### Commit 66

```text
docs: add board porting guide for importing legacy BSP YAML
```

Cieľ: presne vysvetliť preklad:

```yaml
soc_top_name -> top_name
dir          -> direction
standard     -> io_standard
groups       -> nested vector resources
signals      -> scalar resources
```
