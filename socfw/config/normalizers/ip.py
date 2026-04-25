from __future__ import annotations

from copy import deepcopy

from socfw.config.normalized import NormalizedDocument
from socfw.core.diagnostics import Diagnostic, Severity, SourceLocation


def _warn(code: str, file: str, old: str, new: str) -> Diagnostic:
    return Diagnostic(
        code=code,
        severity=Severity.WARNING,
        message=f"Deprecated IP descriptor alias `{old}` used; prefer `{new}`",
        subject="ip.alias",
        spans=(SourceLocation(file=file),),
        hints=(f"Replace `{old}` with `{new}`.",),
    )


def normalize_ip_document(data: dict, *, file: str) -> NormalizedDocument:
    d = deepcopy(data)
    diags: list[Diagnostic] = []
    aliases: list[str] = []

    d.setdefault("origin", {})
    d["origin"].setdefault("kind", "source")
    d["origin"].setdefault("packaging", "plain_rtl")

    d.setdefault("integration", {})
    d.setdefault("reset", {})
    d.setdefault("clocking", {})
    d.setdefault("artifacts", {})
    d["artifacts"].setdefault("synthesis", [])
    d["artifacts"].setdefault("simulation", [])
    d["artifacts"].setdefault("metadata", [])

    # config.needs_bus -> integration.needs_bus
    config = d.get("config")
    if isinstance(config, dict):
        if "needs_bus" in config and "needs_bus" not in d["integration"]:
            d["integration"]["needs_bus"] = bool(config["needs_bus"])
            diag = _warn("IP_ALIAS001", file, "config.needs_bus", "integration.needs_bus")
            diags.append(diag)
            aliases.append(diag.message)

        if "active_high_reset" in config and "active_high" not in d["reset"]:
            d["reset"]["active_high"] = config["active_high_reset"]
            diag = _warn("IP_ALIAS002", file, "config.active_high_reset", "reset.active_high")
            diags.append(diag)
            aliases.append(diag.message)

    # port_bindings.clock/reset
    port_bindings = d.get("port_bindings")
    if isinstance(port_bindings, dict):
        if "clock" in port_bindings and "primary_input_port" not in d["clocking"]:
            d["clocking"]["primary_input_port"] = port_bindings["clock"]
            diag = _warn("IP_ALIAS003", file, "port_bindings.clock", "clocking.primary_input_port")
            diags.append(diag)
            aliases.append(diag.message)

        if "reset" in port_bindings and "port" not in d["reset"]:
            d["reset"]["port"] = port_bindings["reset"]
            diag = _warn("IP_ALIAS004", file, "port_bindings.reset", "reset.port")
            diags.append(diag)
            aliases.append(diag.message)

    # interfaces clock_output -> clocking.outputs
    interfaces = d.get("interfaces")
    if isinstance(interfaces, list):
        outputs = list(d["clocking"].get("outputs") or [])
        ports = list(d.get("ports") or [])

        for iface in interfaces:
            if not isinstance(iface, dict):
                continue

            if iface.get("type") == "clock_output":
                for sig in iface.get("signals", []) or []:
                    if not isinstance(sig, dict):
                        continue

                    name = sig.get("name")
                    if not name:
                        continue

                    if not any(o.get("name") == name for o in outputs if isinstance(o, dict)):
                        outputs.append(
                            {
                                "name": name,
                                "domain_hint": sig.get("top_name"),
                                "frequency_hz": sig.get("frequency_hz"),
                            }
                        )

                    if not any(p.get("name") == name for p in ports if isinstance(p, dict)):
                        ports.append(
                            {
                                "name": name,
                                "direction": sig.get("direction", "output"),
                                "width": int(sig.get("width", 1)),
                            }
                        )

                diag = _warn("IP_ALIAS005", file, "interfaces[type=clock_output]", "clocking.outputs")
                diags.append(diag)
                aliases.append(diag.message)

        d["clocking"]["outputs"] = outputs
        d["ports"] = ports

    # ensure clock/reset ports are present in ports
    ports = list(d.get("ports") or [])

    clk_port = d.get("clocking", {}).get("primary_input_port")
    if clk_port and not any(p.get("name") == clk_port for p in ports if isinstance(p, dict)):
        ports.append({"name": clk_port, "direction": "input", "width": 1})

    rst_port = d.get("reset", {}).get("port")
    if rst_port and not any(p.get("name") == rst_port for p in ports if isinstance(p, dict)):
        ports.append({"name": rst_port, "direction": "input", "width": 1})

    d["ports"] = ports

    return NormalizedDocument(
        data=d,
        diagnostics=diags,
        aliases_used=aliases,
    )
