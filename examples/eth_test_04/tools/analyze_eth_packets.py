#!/usr/bin/env python3
"""Classify Ethernet trace packets from eth_hw_trace.sh packets_full.tsv.

Input TSV columns produced by tshark:
  frame.number, frame.time_relative, frame.len, eth.src, eth.dst, eth.type,
  ip.src, ip.dst, udp.srcport, udp.dstport, data.data

Outputs:
  - packets_classified.tsv
  - analysis_summary.txt

The classifier is intentionally project-aware:
  * UDP_ECHO: FPGA returns IP/UDP response with swapped IPs/ports.
  * L2_ECHO: FPGA returns the original IP/UDP packet but swaps only Ethernet MACs.
  * BAD_L2_REPLY: FPGA generates an IP/UDP-like reply but Ethernet dst is not PC MAC.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass
class Packet:
    number: str = ""
    time: str = ""
    frame_len: str = ""
    eth_src: str = ""
    eth_dst: str = ""
    eth_type: str = ""
    ip_src: str = ""
    ip_dst: str = ""
    udp_src: str = ""
    udp_dst: str = ""
    data_hex: str = ""
    cls: str = "OTHER"

    @property
    def data_bytes(self) -> bytes:
        txt = (self.data_hex or "").replace(":", "").replace(" ", "").strip()
        if not txt:
            return b""
        try:
            return bytes.fromhex(txt)
        except ValueError:
            return b""

    @property
    def data_sha256(self) -> str:
        return hashlib.sha256(self.data_bytes).hexdigest() if self.data_bytes else ""

    @property
    def data_prefix(self) -> str:
        return self.data_bytes[:32].hex()

    @property
    def data_len(self) -> int:
        return len(self.data_bytes)


def norm_mac(mac: str) -> str:
    return mac.lower().strip()


def norm_ip(ip: str) -> str:
    return ip.strip()


def read_packets(path: Path) -> list[Packet]:
    rows: list[Packet] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f, delimiter="\t")
        for cols in reader:
            if not cols or cols[0].startswith("#"):
                continue
            cols = cols + [""] * (11 - len(cols))
            rows.append(Packet(*cols[:11]))
    return rows


def classify_packets(
    packets: Iterable[Packet],
    pc_mac: str,
    fpga_mac: str,
    pc_ip: str,
    fpga_ip: str,
    fpga_port: str,
) -> list[Packet]:
    pc_mac = norm_mac(pc_mac)
    fpga_mac = norm_mac(fpga_mac)
    pc_ip = norm_ip(pc_ip)
    fpga_ip = norm_ip(fpga_ip)
    fpga_port = str(fpga_port)

    out: list[Packet] = []
    for p in packets:
        eth_src = norm_mac(p.eth_src)
        eth_dst = norm_mac(p.eth_dst)
        ip_src = norm_ip(p.ip_src)
        ip_dst = norm_ip(p.ip_dst)
        udp_src = str(p.udp_src)
        udp_dst = str(p.udp_dst)

        if (
            eth_src == pc_mac and eth_dst == fpga_mac
            and ip_src == pc_ip and ip_dst == fpga_ip
            and udp_dst == fpga_port
        ):
            p.cls = "PC_TO_FPGA_UDP"
        elif (
            eth_src == fpga_mac and eth_dst == pc_mac
            and ip_src == fpga_ip and ip_dst == pc_ip
            and udp_src == fpga_port
        ):
            p.cls = "FPGA_TO_PC_UDP_ECHO"
        elif (
            eth_src == fpga_mac and eth_dst == pc_mac
            and ip_src == pc_ip and ip_dst == fpga_ip
            and udp_dst == fpga_port
        ):
            p.cls = "FPGA_TO_PC_L2_ECHO"
        elif (
            eth_src == fpga_mac and eth_dst != pc_mac
            and ip_src == fpga_ip and ip_dst == pc_ip
            and udp_src == fpga_port
        ):
            p.cls = "FPGA_BAD_L2_DST_UDP_REPLY"
        elif eth_src == fpga_mac:
            p.cls = "FPGA_OTHER"
        elif eth_dst == fpga_mac:
            p.cls = "TO_FPGA_OTHER"
        elif p.eth_type.lower() == "0x0806" or p.eth_type.lower() == "0806":
            p.cls = "ARP"
        else:
            p.cls = "OTHER"
        out.append(p)
    return out


def write_classified(path: Path, packets: list[Packet]) -> None:
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow([
            "frame", "time", "len", "class", "eth.src", "eth.dst", "eth.type",
            "ip.src", "ip.dst", "udp.src", "udp.dst", "data_len", "data_sha256", "data_prefix32",
        ])
        for p in packets:
            writer.writerow([
                p.number, p.time, p.frame_len, p.cls, p.eth_src, p.eth_dst, p.eth_type,
                p.ip_src, p.ip_dst, p.udp_src, p.udp_dst, p.data_len, p.data_sha256, p.data_prefix,
            ])


def summarize(packets: list[Packet]) -> tuple[str, int]:
    counts: dict[str, int] = {}
    for p in packets:
        counts[p.cls] = counts.get(p.cls, 0) + 1

    req = counts.get("PC_TO_FPGA_UDP", 0)
    udp_echo = counts.get("FPGA_TO_PC_UDP_ECHO", 0)
    l2_echo = counts.get("FPGA_TO_PC_L2_ECHO", 0)
    bad_l2 = counts.get("FPGA_BAD_L2_DST_UDP_REPLY", 0)
    fpga_other = counts.get("FPGA_OTHER", 0)

    if req == 0:
        diagnosis = "No PC->FPGA UDP requests captured; capture filter/interface/test setup may be wrong."
        exit_code = 2
    elif udp_echo:
        diagnosis = "UDP/IP echo replies are present in pcap. If socket test fails, inspect checksum, timing, or host filtering."
        exit_code = 0
    elif l2_echo and not udp_echo:
        diagnosis = "L2/MAC echo works, but UDP/IP headers are not swapped/recomputed; UDP socket test is expected to fail."
        exit_code = 1
    elif bad_l2:
        diagnosis = "FPGA emits UDP-like replies, but Ethernet destination MAC is not the PC MAC; inspect TX metadata/header builder."
        exit_code = 1
    elif fpga_other:
        diagnosis = "FPGA-originated frames exist, but no recognizable UDP echo; inspect TX framing/FCS/protocol builder."
        exit_code = 1
    else:
        diagnosis = "PC requests captured, but no FPGA-originated reply frames; inspect RX accept path, FIFOs, echo app, and TX start."
        exit_code = 1

    lines = [
        "Ethernet trace analysis summary",
        "================================",
        "",
        "Class counts:",
    ]
    for key in sorted(counts):
        lines.append(f"  {key}: {counts[key]}")
    lines.extend([
        "",
        f"PC->FPGA UDP requests: {req}",
        f"FPGA UDP/IP echoes:    {udp_echo}",
        f"FPGA L2 echoes:        {l2_echo}",
        f"FPGA bad-L2 replies:   {bad_l2}",
        "",
        f"Diagnosis: {diagnosis}",
    ])
    return "\n".join(lines) + "\n", exit_code


def main() -> int:
    ap = argparse.ArgumentParser(description="Classify eth_test packet capture TSV")
    ap.add_argument("packets_tsv", type=Path)
    ap.add_argument("--pc-mac", required=True)
    ap.add_argument("--fpga-mac", required=True)
    ap.add_argument("--pc-ip", default="192.168.0.3")
    ap.add_argument("--fpga-ip", default="192.168.0.2")
    ap.add_argument("--fpga-port", default="8080")
    ap.add_argument("--out-dir", type=Path, default=None)
    args = ap.parse_args()

    out_dir = args.out_dir or args.packets_tsv.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    packets = read_packets(args.packets_tsv)
    packets = classify_packets(
        packets,
        pc_mac=args.pc_mac,
        fpga_mac=args.fpga_mac,
        pc_ip=args.pc_ip,
        fpga_ip=args.fpga_ip,
        fpga_port=args.fpga_port,
    )

    classified_path = out_dir / "packets_classified.tsv"
    summary_path = out_dir / "analysis_summary.txt"
    write_classified(classified_path, packets)
    summary, exit_code = summarize(packets)
    summary_path.write_text(summary, encoding="utf-8")
    print(summary, end="")
    print(f"\nWrote: {classified_path}")
    print(f"Wrote: {summary_path}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
