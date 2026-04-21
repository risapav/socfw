"""Legacy YAML → v2 migration transforms.

Each function receives the raw parsed dict of a legacy file and returns
a new dict conforming to the v2 schema.  None of these functions modify
the input in place.
"""
from __future__ import annotations

from typing import Any


# ---------------------------------------------------------------------------
# Board YAML migration
# ---------------------------------------------------------------------------

def migrate_board(legacy: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"version": 2, "kind": "board"}

    board_id = legacy.get("board", {}).get("id") or legacy.get("id", "unknown")
    out["board"] = {
        "id": board_id,
        "vendor": legacy.get("board", {}).get("vendor", ""),
        "title": legacy.get("board", {}).get("title", ""),
    }

    dev = legacy.get("device", {})
    out["fpga"] = {
        "family": dev.get("family", ""),
        "part": dev.get("part", ""),
        "package": dev.get("package", ""),
        "pins": dev.get("pins", 0),
        "speed": dev.get("speed", 0),
        "hdl_default": dev.get("hdl", "SystemVerilog_2005"),
    }

    sys = legacy.get("system", {})
    clk = sys.get("clock", {})
    rst = sys.get("reset", {})
    out["system"] = {
        "clock": {
            "name": clk.get("name", "sys_clk"),
            "top_name": clk.get("port", clk.get("top_name", "SYS_CLK")),
            "pin": clk.get("pin", ""),
            "io_standard": clk.get("standard", clk.get("io_standard", "3.3-V LVTTL")),
            "frequency_hz": _mhz_to_hz(clk.get("freq_mhz")) or clk.get("frequency_hz", 50_000_000),
            "period_ns": clk.get("period_ns", 20.0),
        },
        "reset": {
            "name": rst.get("name", "sys_reset_n"),
            "top_name": rst.get("port", rst.get("top_name", "RESET_N")),
            "pin": rst.get("pin", ""),
            "io_standard": rst.get("standard", rst.get("io_standard", "3.3-V LVTTL")),
            "active_low": rst.get("active_low", True),
        },
    }

    onboard: dict[str, Any] = {}
    for name, resource in legacy.get("onboard", {}).items():
        migrated = _migrate_board_resource(resource)
        if migrated:
            onboard[name] = migrated

    connectors: dict[str, Any] = {}
    for bank_name, bank in legacy.get("connectors", {}).items():
        connectors[bank_name] = bank

    out["resources"] = {
        "onboard": onboard,
        "connectors": connectors,
    }

    return out


def _migrate_board_resource(resource: dict[str, Any]) -> dict[str, Any]:
    out = dict(resource)
    if "soc_top_name" in out:
        out["top_name"] = out.pop("soc_top_name")
    if "standard" in out:
        out["io_standard"] = out.pop("standard")
    if "dir" in out:
        out["direction"] = out.pop("dir")
    out.pop("enabled_var", None)

    for key in ("signals", "groups"):
        if key in out:
            out[key] = {
                k: _migrate_board_resource(v) if isinstance(v, dict) else v
                for k, v in out[key].items()
            }
    return out


# ---------------------------------------------------------------------------
# Project YAML migration
# ---------------------------------------------------------------------------

def migrate_project(legacy: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"version": 2}

    design = legacy.get("design", {})
    board = legacy.get("board", {})
    out["project"] = {
        "name": design.get("name", legacy.get("project", {}).get("name", "unknown")),
        "mode": design.get("mode", "standalone"),
        "board": board.get("type", board.get("ref", "")),
        "board_file": board.get("file", ""),
        "output_dir": legacy.get("output_dir", "build/gen"),
        "debug": legacy.get("debug", False),
    }

    # ip search paths
    ip_paths: list[str] = (
        legacy.get("registries", {}).get("ip", [])
        or legacy.get("plugins", {}).get("ip", [])
        or legacy.get("paths", {}).get("ip_plugins", [])
    )
    out["registries"] = {"ip": ip_paths}

    # feature enablement from onboard flags
    features: list[str] = []
    for key, val in legacy.get("onboard", {}).items():
        if val is True:
            features.append(f"board:onboard.{key}")
    for key, val in legacy.items():
        if key.startswith("pmod_") and val is True:
            parts = key.split("_", 2)
            if len(parts) >= 3:
                connector = parts[1].upper()
                role = parts[2]
                features.append(f"board:connector.pmod.{connector}.role.{role}")
    out["features"] = {"use": features}

    # clocks
    out["clocks"] = _migrate_project_clocks(legacy)

    # modules
    out["modules"] = _migrate_modules(legacy.get("modules", {}))

    # timing ref
    timing_file = legacy.get("timing", {}).get("file")
    if timing_file:
        out["timing"] = {"file": timing_file}

    out["artifacts"] = legacy.get("artifacts", {"emit": ["rtl", "board", "docs"]})

    return out


def _migrate_project_clocks(legacy: dict[str, Any]) -> list[dict[str, Any]]:
    clocks = []
    soc = legacy.get("soc", {})

    primary: dict[str, Any] = {
        "name": "sys",
        "source": "board:SYS_CLK",
        "frequency_hz": soc.get("clock_freq", 50_000_000),
        "reset": {"signal": "board:RESET_N", "active_low": True, "sync_stages": 2},
    }
    clocks.append(primary)

    for domain_name, domain in legacy.get("clock_domains", {}).items():
        if isinstance(domain, dict) and "source" in domain:
            clocks.append({
                "name": domain_name,
                "source": domain["source"],
                "frequency_hz": domain.get("frequency_hz", 0),
            })

    return clocks


def _migrate_modules(modules_raw: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    if isinstance(modules_raw, dict):
        for inst_name, mod in modules_raw.items():
            if not isinstance(mod, dict):
                continue
            entry: dict[str, Any] = {
                "instance": inst_name,
                "type": mod.get("type", mod.get("module", inst_name)),
            }
            clocks = mod.get("clock_domains", mod.get("clocks", {}))
            if clocks:
                entry["clocks"] = clocks
            if mod.get("params"):
                entry["params"] = mod["params"]
            bind_ports = _migrate_port_overrides(mod.get("port_overrides", {}))
            if bind_ports:
                entry["bind"] = {"ports": bind_ports}
            result.append(entry)
    elif isinstance(modules_raw, list):
        result = modules_raw
    return result


def _migrate_port_overrides(overrides: Any) -> dict[str, Any]:
    if not isinstance(overrides, dict):
        return {}
    result: dict[str, Any] = {}
    for port, override in overrides.items():
        if isinstance(override, str):
            result[port] = {"target": override}
        elif isinstance(override, dict):
            entry: dict[str, Any] = {}
            if "target" in override:
                entry["target"] = override["target"]
            if "name" in override:
                entry["top_name"] = override["name"]
            if "width" in override:
                entry["width"] = override["width"]
            if "pad" in override:
                entry["adapt"] = override["pad"]
            if "adapt" in override:
                entry["adapt"] = override["adapt"]
            result[port] = entry
    return result


# ---------------------------------------------------------------------------
# Timing YAML migration
# ---------------------------------------------------------------------------

def migrate_timing(legacy: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"version": 2, "kind": "timing"}

    out["timing"] = {
        "derive_uncertainty": legacy.get("derive_uncertainty", True),
    }

    out["clocks"] = _migrate_timing_clocks(legacy.get("clocks", []))
    out["generated_clocks"] = _migrate_plls(legacy.get("plls", []))
    out["clock_groups"] = legacy.get("clock_groups", [])
    out["false_paths"] = legacy.get("false_paths", [])

    io = legacy.get("io_delays", {})
    out["io_delays"] = {
        "auto": io.get("auto", True),
        "default_input_max_ns": io.get("default_input_max_ns", 2.5),
        "default_output_max_ns": io.get("default_output_max_ns", 2.5),
        "overrides": io.get("overrides", []),
    }

    return out


def _migrate_timing_clocks(clocks: list[Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for c in clocks:
        if not isinstance(c, dict):
            continue
        entry: dict[str, Any] = {
            "name": c.get("name", ""),
            "source": c.get("source", c.get("port", "")),
            "period_ns": c.get("period_ns", 0.0),
            "uncertainty_ns": c.get("uncertainty_ns", 0.0),
        }
        if "reset" in c:
            rst = c["reset"]
            entry["reset"] = {
                "source": rst.get("source", rst.get("port", "")),
                "active_low": rst.get("active_low", True),
                "sync_stages": rst.get("sync_stages", 2),
            }
        result.append(entry)
    return result


def _migrate_plls(plls: list[Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for pll in plls:
        if not isinstance(pll, dict):
            continue
        for output in pll.get("outputs", []):
            entry: dict[str, Any] = {
                "name": output.get("domain", ""),
                "source": {
                    "instance": pll.get("inst", ""),
                    "output": output.get("port", ""),
                },
                "multiply_by": pll.get("multiply_by", 1),
                "divide_by": pll.get("divide_by", 1),
                "phase_shift_ps": output.get("phase_shift_ps", 0),
            }
            if "reset" in output:
                entry["reset"] = output["reset"]
            result.append(entry)
    return result


# ---------------------------------------------------------------------------
# IP YAML migration
# ---------------------------------------------------------------------------

def migrate_ip(legacy: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"version": 2, "kind": "ip"}

    out["name"] = legacy.get("name", legacy.get("module", "unknown"))
    out["module"] = legacy.get("module", out["name"])
    out["category"] = legacy.get("type", "custom")

    is_vendor = bool(legacy.get("files") and any(
        f.endswith(".qip") or f.endswith(".xci") for f in legacy.get("files", [])
    ))
    out["origin"] = {
        "kind": "vendor_generated" if is_vendor else "source",
        "tool": "quartus" if is_vendor else None,
        "packaging": "qip" if is_vendor else None,
    }

    out["integration"] = {
        "bus": "none" if not legacy.get("needs_bus", False) else "slave",
        "generate_registers": legacy.get("gen_regs", False),
        "instantiate": not legacy.get("dependency_only", False),
        "dependency_only": legacy.get("dependency_only", False),
    }

    port_map = legacy.get("port_map", {})
    out["reset"] = {
        "port": port_map.get("rst_n") or port_map.get("rst") or port_map.get("areset"),
        "bypass_sync": legacy.get("bypass_rst_sync", False),
        "active_high": legacy.get("active_high_rst", False),
        "optional": legacy.get("reset_optional", False),
        "asynchronous": legacy.get("async_reset", False),
    }

    out["clocking"] = {
        "primary_input": port_map.get("clk"),
        "outputs": _migrate_ip_clock_outputs(legacy.get("interfaces", {})),
    }

    files = legacy.get("files", [])
    synthesis = [f for f in files if f.endswith((".qip", ".xci", ".v", ".sv")) and "_bb" not in f]
    simulation = [f for f in files if "_bb" in f or f.endswith(".vhd")]
    metadata = [f for f in files if f.endswith((".ppf", ".tcl", ".qsf"))]
    out["artifacts"] = {
        "synthesis": synthesis,
        "simulation": simulation,
        "metadata": metadata,
    }

    return out


def _migrate_ip_clock_outputs(interfaces: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for iface_name, iface in interfaces.items():
        if not isinstance(iface, dict):
            continue
        if iface.get("type") == "clock_output":
            for sig_name, sig in iface.get("signals", {}).items():
                kind = "status" if sig_name == "locked" else "generated_clock"
                result.append({
                    "port": sig_name,
                    "domain": sig.get("domain"),
                    "kind": kind,
                    "signal_name": sig.get("signal_name"),
                })
    return result


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _mhz_to_hz(mhz: Any) -> int | None:
    if mhz is None:
        return None
    try:
        return int(float(mhz) * 1_000_000)
    except (TypeError, ValueError):
        return None
