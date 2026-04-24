from __future__ import annotations

from pathlib import Path


def needs_bridge_scaffold(system) -> bool:
    for mod in system.project.modules:
        if mod.bus is None:
            continue

        fabric = system.project.fabric_by_name(mod.bus.fabric)
        if fabric is None:
            continue

        ip = system.ip_catalog.get(mod.type_name)
        if ip is None:
            continue

        iface = ip.bus_interface(role="slave")
        if iface is None:
            continue

        if fabric.protocol == "simple_bus" and iface.protocol == "wishbone":
            return True

    return False


def patch_soc_top_with_bridge_scaffold(out_dir: str, system) -> str | None:
    if system is None or not needs_bridge_scaffold(system):
        return None

    soc_top = Path(out_dir) / "rtl" / "soc_top.sv"
    if not soc_top.exists():
        return None

    text = soc_top.read_text(encoding="utf-8")
    marker = "// socfw compatibility bridge scaffold"

    if marker in text:
        return str(soc_top)

    insert_block = """

  // socfw compatibility bridge scaffold
  // NOTE: temporary Phase-1/Phase-2 insertion until full bridge RTL planning is implemented.
  simple_bus_to_wishbone_bridge u_bridge_sdram0 (
    .clk(1'b0),
    .reset_n(1'b1),
    .sb_addr(32'h0),
    .sb_wdata(32'h0),
    .sb_be(4'h0),
    .sb_we(1'b0),
    .sb_valid(1'b0),
    .sb_rdata(),
    .sb_ready(),
    .wb_adr(),
    .wb_dat_w(),
    .wb_dat_r(32'h0),
    .wb_sel(),
    .wb_we(),
    .wb_cyc(),
    .wb_stb(),
    .wb_ack(1'b0)
  );
"""

    idx = text.rfind("endmodule")
    if idx == -1:
        return None

    patched = text[:idx].rstrip() + insert_block + "\nendmodule\n"
    soc_top.write_text(patched, encoding="utf-8")
    return str(soc_top)
