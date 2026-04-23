# Bus and Bridge Architecture

## Overview

The SoC framework uses a layered bus architecture:

```
CPU (simple_bus master)
   ↓
simple_bus fabric
   ↓ (direct)          ↓ (via bridge)
simple_bus slave    AXI-lite slave / Wishbone slave / ...
```

## Core fabric: `simple_bus`

A minimal synchronous bus with:
- `addr[31:0]` — byte address
- `wdata[31:0]` — write data
- `rdata[31:0]` — read data
- `be[3:0]` — byte enable
- `we` — write enable
- `valid` — transaction request
- `ready` — slave response

Defined in `src/ip/bus/bus_if.sv`.

## Bridge plugin model

Bridge planners implement:

```python
class MyBridgePlanner:
    src_protocol = "simple_bus"
    dst_protocol = "my_protocol"
    bridge_module = "simple_bus_to_my_protocol_bridge"

    def can_bridge(self, *, fabric, ip, iface) -> bool: ...
    def plan_bridge(self, *, fabric, mod, ip, iface) -> PlannedBusBridge: ...
```

Registered via `registry.register_bridge_planner(MyBridgePlanner())`.

The bus planner automatically selects the bridge when it detects a protocol mismatch.

## Implemented bridges

| Source       | Destination  | Module                            |
|--------------|--------------|-----------------------------------|
| `simple_bus` | `axi_lite`   | `simple_bus_to_axi_lite_bridge`   |
| `simple_bus` | `wishbone`   | `simple_bus_to_wishbone_bridge`   |

## Adding a new bridge

1. Create `socfw/plugins/bridges/simple_to_<protocol>.py`
2. Implement `can_bridge` and `plan_bridge`
3. Register in `socfw/plugins/bootstrap.py`
4. Add RTL module at `src/ip/bus/simple_bus_to_<protocol>_bridge.sv`
5. The bus planner, RTL builder, and validation all work automatically.
