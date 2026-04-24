from __future__ import annotations

from pathlib import Path


def bridge_instance_block(bridge) -> str:
    return f"""
  // socfw planned bridge instance
  {bridge.kind}_bridge {bridge.instance} (
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


def inject_bridge_instances(out_dir: str, planned_bridges: list) -> str | None:
    if not planned_bridges:
        return None

    soc_top = Path(out_dir) / "rtl" / "soc_top.sv"
    if not soc_top.exists():
        return None

    text = soc_top.read_text(encoding="utf-8")
    marker = "// socfw planned bridge instance"

    if marker in text:
        return str(soc_top)

    blocks = "".join(bridge_instance_block(b) for b in planned_bridges)

    idx = text.rfind("endmodule")
    if idx == -1:
        return None

    patched = text[:idx].rstrip() + "\n" + blocks + "\nendmodule\n"
    soc_top.write_text(patched, encoding="utf-8")
    return str(soc_top)
