#!/usr/bin/env bash
# eth_hw_trace.sh -- unified HW trace runner for eth_test_03 and eth_test_04
# VERSION: 2026-06-06-fix3-pc-ip-and-capture-tool
#
# Purpose:
#   - set static ARP for FPGA
#   - start Wireshark-compatible capture (.pcapng) via dumpcap/tshark/tcpdump/wireshark
#   - optionally start UART tap reader
#   - run selected HW test
#   - collect metadata, NIC counters, packet summaries and analysis files

set -uo pipefail

VERSION="2026-06-06-fix3-pc-ip-and-capture-tool"

PROJECT="auto"
TEST_KIND="udp"
FPGA_IP="192.168.0.2"
FPGA_MAC="00:0a:35:01:fe:c0"
FPGA_PORT="8080"
PC_IP=""
PC_IFACE="enp0s31f6"
TAP_PORT="/dev/ttyUSB0"
TAP_BAUD="115200"
TAP_BYTES="auto"
UDP_TIMEOUT="1.5"
LOOPBACK_MODE="clean"
LOOPBACK_BCAST=0
USE_TAP=0
NO_ARP=0
OPEN_WIRESHARK=0
CAPTURE_TOOL="auto"
CAPTURE_PROFILE="udp-strict"
CAPTURE_SECONDS=0
OUT_ROOT="captures"

usage() {
  cat <<USAGE
eth_hw_trace.sh ${VERSION}

Usage:
  ./tools/eth_hw_trace.sh --project eth04 --test udp --tap --capture-tool tcpdump

Options:
  --project eth03|eth04|auto
  --test udp|loopback-clean|loopback-raw|loopback-bcast|sniff
  --ip IP                        FPGA IP [${FPGA_IP}]
  --mac MAC                      FPGA MAC [${FPGA_MAC}]
  --port PORT                    FPGA UDP port [${FPGA_PORT}]
  --pc-ip IP                     PC IP, optional; auto-detected if omitted
  --iface IFACE                  PC network interface [${PC_IFACE}]
  --tap                          Run UART tap reader in parallel
  --tap-port DEV                 UART tap port [${TAP_PORT}]
  --tap-baud BAUD                UART tap baud [${TAP_BAUD}]
  --tap-bytes N|auto             Bytes per UART frame [auto]
  --timeout SEC                  Per-frame timeout [${UDP_TIMEOUT}]
  --no-arp                       Do not update static ARP
  --capture-tool TOOL            auto|dumpcap|tshark|tcpdump|wireshark [auto]
  --capture-profile PROFILE      udp-strict|broad|l2-loopback [udp-strict]
  --capture-seconds SEC          Fixed capture duration; 0 = test-controlled [0]
  --out-dir DIR                  Output root directory [captures]
  --open-wireshark               Open resulting pcapng in Wireshark GUI
  -h|--help                      Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --test) TEST_KIND="$2"; shift 2 ;;
    --ip) FPGA_IP="$2"; shift 2 ;;
    --mac) FPGA_MAC="$2"; shift 2 ;;
    --port) FPGA_PORT="$2"; shift 2 ;;
    --pc-ip) PC_IP="$2"; shift 2 ;;
    --iface) PC_IFACE="$2"; shift 2 ;;
    --tap) USE_TAP=1; shift ;;
    --tap-port) TAP_PORT="$2"; shift 2 ;;
    --tap-baud) TAP_BAUD="$2"; shift 2 ;;
    --tap-bytes) TAP_BYTES="$2"; shift 2 ;;
    --timeout) UDP_TIMEOUT="$2"; shift 2 ;;
    --no-arp) NO_ARP=1; shift ;;
    --capture-tool) CAPTURE_TOOL="$2"; shift 2 ;;
    --capture-profile) CAPTURE_PROFILE="$2"; shift 2 ;;
    --capture-seconds) CAPTURE_SECONDS="$2"; shift 2 ;;
    --out-dir) OUT_ROOT="$2"; shift 2 ;;
    --open-wireshark) OPEN_WIRESHARK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -E bash "$0" \
    --project "$PROJECT" --test "$TEST_KIND" --ip "$FPGA_IP" --mac "$FPGA_MAC" --port "$FPGA_PORT" \
    ${PC_IP:+--pc-ip "$PC_IP"} --iface "$PC_IFACE" \
    ${USE_TAP:+--tap} --tap-port "$TAP_PORT" --tap-baud "$TAP_BAUD" --tap-bytes "$TAP_BYTES" \
    --timeout "$UDP_TIMEOUT" ${NO_ARP:+--no-arp} --capture-tool "$CAPTURE_TOOL" \
    --capture-profile "$CAPTURE_PROFILE" --capture-seconds "$CAPTURE_SECONDS" --out-dir "$OUT_ROOT" \
    ${OPEN_WIRESHARK:+--open-wireshark}
fi

if [[ "$PROJECT" == "auto" ]]; then
  cwd_base="$(basename "$PWD")"
  case "$cwd_base" in
    eth_test_03) PROJECT="eth03" ;;
    eth_test_04) PROJECT="eth04" ;;
    *) PROJECT="eth" ;;
  esac
fi

if [[ -z "$PC_IP" ]]; then
  PC_IP="$(ip -4 -o addr show dev "$PC_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
fi
PC_MAC="$(cat "/sys/class/net/${PC_IFACE}/address" 2>/dev/null || echo unknown)"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_ROOT}/${PROJECT}_${TEST_KIND}_${TS}"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/run.log"
PCAP="$OUT_DIR/wire_capture.pcapng"
TEST_OUT="$OUT_DIR/test_output.txt"
UART_LOG="$OUT_DIR/uart_tap.log"
META="$OUT_DIR/meta.txt"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"
}

cleanup_pids=()
cleanup() {
  for pid in "${cleanup_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

capture_filter() {
  case "$CAPTURE_PROFILE" in
    udp-strict)
      printf '(udp port %s and host %s) or arp' "$FPGA_PORT" "$FPGA_IP"
      ;;
    broad)
      printf 'ether host %s or host %s or udp port %s or arp or ether proto 0x9000' "$FPGA_MAC" "$FPGA_IP" "$FPGA_PORT"
      ;;
    l2-loopback)
      printf 'ether proto 0x9000 or ether host %s' "$FPGA_MAC"
      ;;
    *)
      printf '(udp port %s and host %s) or arp' "$FPGA_PORT" "$FPGA_IP"
      ;;
  esac
}

FILTER="$(capture_filter)"

{
  echo "version=${VERSION}"
  echo "timestamp=${TS}"
  echo "project=${PROJECT}"
  echo "test_kind=${TEST_KIND}"
  echo "iface=${PC_IFACE}"
  echo "pc_ip=${PC_IP}"
  echo "pc_mac=${PC_MAC}"
  echo "fpga_ip=${FPGA_IP}"
  echo "fpga_mac=${FPGA_MAC}"
  echo "fpga_port=${FPGA_PORT}"
  echo "capture_tool_requested=${CAPTURE_TOOL}"
  echo "capture_profile=${CAPTURE_PROFILE}"
  echo "capture_filter=${FILTER}"
  echo "pwd=${PWD}"
  echo "cmdline=$0 $*"
  ip addr show dev "$PC_IFACE" || true
  ip route get "$FPGA_IP" || true
  ip neigh show dev "$PC_IFACE" || true
  ethtool "$PC_IFACE" || true
} > "$META" 2>&1

log "eth_hw_trace.sh version: ${VERSION}"
log "Output directory: ${OUT_DIR}"
log "Project=${PROJECT} test=${TEST_KIND} iface=${PC_IFACE} pc=${PC_IP}/${PC_MAC} fpga=${FPGA_IP}/${FPGA_MAC}:${FPGA_PORT}"
log "Capture requested tool=${CAPTURE_TOOL} profile=${CAPTURE_PROFILE}"

if [[ "$NO_ARP" -eq 0 ]]; then
  log "Installing static ARP: ${FPGA_IP} -> ${FPGA_MAC} on ${PC_IFACE}"
  ip neigh replace "$FPGA_IP" lladdr "$FPGA_MAC" nud permanent dev "$PC_IFACE" >>"$LOG" 2>&1 || true
fi

ethtool -S "$PC_IFACE" > "$OUT_DIR/nic_errors_before.txt" 2>&1 || true

start_capture_one() {
  local tool="$1"
  local stderr_file="$OUT_DIR/capture_${tool}.stderr"
  log "Trying capture tool: ${tool}"
  case "$tool" in
    dumpcap)
      command -v dumpcap >/dev/null 2>&1 || return 127
      if [[ "$CAPTURE_SECONDS" != "0" ]]; then
        dumpcap -i "$PC_IFACE" -f "$FILTER" -a "duration:${CAPTURE_SECONDS}" -w "$PCAP" -q >>"$LOG" 2>"$stderr_file" &
      else
        dumpcap -i "$PC_IFACE" -f "$FILTER" -w "$PCAP" -q >>"$LOG" 2>"$stderr_file" &
      fi
      ;;
    tshark)
      command -v tshark >/dev/null 2>&1 || return 127
      if [[ "$CAPTURE_SECONDS" != "0" ]]; then
        tshark -i "$PC_IFACE" -f "$FILTER" -a "duration:${CAPTURE_SECONDS}" -w "$PCAP" >>"$LOG" 2>"$stderr_file" &
      else
        tshark -i "$PC_IFACE" -f "$FILTER" -w "$PCAP" >>"$LOG" 2>"$stderr_file" &
      fi
      ;;
    tcpdump)
      command -v tcpdump >/dev/null 2>&1 || return 127
      if [[ "$CAPTURE_SECONDS" != "0" ]]; then
        timeout "$CAPTURE_SECONDS" tcpdump -U -i "$PC_IFACE" -w "$PCAP" "$FILTER" >>"$LOG" 2>"$stderr_file" &
      else
        tcpdump -U -i "$PC_IFACE" -w "$PCAP" "$FILTER" >>"$LOG" 2>"$stderr_file" &
      fi
      ;;
    wireshark)
      command -v wireshark >/dev/null 2>&1 || return 127
      wireshark -k -i "$PC_IFACE" -f "$FILTER" -w "$PCAP" >>"$LOG" 2>"$stderr_file" &
      ;;
    *)
      return 2
      ;;
  esac
  local pid=$!
  sleep 0.8
  if kill -0 "$pid" 2>/dev/null; then
    cleanup_pids+=("$pid")
    echo "$tool" > "$OUT_DIR/capture_tool_used.txt"
    log "Capture running via ${tool}, pid=${pid}"
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  log "Capture tool ${tool} failed to stay running; stderr follows:"
  sed 's/^/  /' "$stderr_file" | tee -a "$LOG" || true
  return 1
}

start_capture() {
  if [[ "$CAPTURE_TOOL" != "auto" ]]; then
    start_capture_one "$CAPTURE_TOOL"
    return $?
  fi
  for tool in dumpcap tshark tcpdump; do
    if start_capture_one "$tool"; then
      return 0
    fi
  done
  return 1
}

if ! start_capture; then
  log "ERROR: no capture tool could be started"
  log "Last 80 lines of run.log:"
  tail -80 "$LOG" || true
  exit 1
fi

if [[ "$USE_TAP" -eq 1 ]]; then
  if ! python3 -c 'import serial' >/dev/null 2>&1; then
    log "WARNING: --tap requested, but pyserial is not installed; UART tap disabled"
    echo "pyserial missing: install python3-pyserial or python3 -m pip install pyserial" > "$UART_LOG"
  else
    TAP_BYTES_ARG=()
    if [[ "$TAP_BYTES" != "auto" ]]; then
      TAP_BYTES_ARG=(--bytes "$TAP_BYTES")
    fi
    if [[ -f tools/read_tap.py ]]; then
      python3 tools/read_tap.py --port "$TAP_PORT" --baud "$TAP_BAUD" "${TAP_BYTES_ARG[@]}" > "$UART_LOG" 2>&1 &
      cleanup_pids+=("$!")
      log "UART tap started: ${TAP_PORT} @ ${TAP_BAUD}, pid=$!"
      sleep 0.5
    else
      log "WARNING: tools/read_tap.py not found; UART tap disabled"
      echo "tools/read_tap.py not found" > "$UART_LOG"
    fi
  fi
fi

run_test() {
  case "$TEST_KIND" in
    udp)
      if [[ -f test_fpga.py ]]; then
        python3 test_fpga.py --ip "$FPGA_IP" --mac "$FPGA_MAC" --iface "$PC_IFACE" --port "$FPGA_PORT" --timeout "$UDP_TIMEOUT"
      else
        echo "ERROR: test_fpga.py not found" >&2
        return 127
      fi
      ;;
    loopback-clean)
      if [[ -f test_loopback.py ]]; then
        python3 test_loopback.py --iface "$PC_IFACE" --fpga-mac "$FPGA_MAC" --mode clean --timeout "$UDP_TIMEOUT"
      else
        echo "ERROR: test_loopback.py not found" >&2
        return 127
      fi
      ;;
    loopback-raw)
      if [[ -f test_loopback.py ]]; then
        python3 test_loopback.py --iface "$PC_IFACE" --fpga-mac "$FPGA_MAC" --mode raw --timeout "$UDP_TIMEOUT"
      else
        echo "ERROR: test_loopback.py not found" >&2
        return 127
      fi
      ;;
    loopback-bcast)
      if [[ -f test_loopback.py ]]; then
        python3 test_loopback.py --iface "$PC_IFACE" --fpga-mac "$FPGA_MAC" --mode raw --broadcast --timeout "$UDP_TIMEOUT"
      else
        echo "ERROR: test_loopback.py not found" >&2
        return 127
      fi
      ;;
    sniff)
      sleep "${CAPTURE_SECONDS:-5}"
      ;;
    *)
      echo "ERROR: unknown test kind ${TEST_KIND}" >&2
      return 2
      ;;
  esac
}

log "Running test: ${TEST_KIND}"
set +e
run_test > "$TEST_OUT" 2>&1
TEST_RC=$?
set -e
cat "$TEST_OUT" | tee -a "$LOG" || true
log "Test return code: ${TEST_RC}"

# Give capture backend time to flush packets.
sleep 1
cleanup
trap - EXIT

ethtool -S "$PC_IFACE" > "$OUT_DIR/nic_errors_after.txt" 2>&1 || true
diff -u "$OUT_DIR/nic_errors_before.txt" "$OUT_DIR/nic_errors_after.txt" > "$OUT_DIR/nic_errors.diff" 2>/dev/null || true

if command -v tshark >/dev/null 2>&1 && [[ -s "$PCAP" ]]; then
  tshark -r "$PCAP" -T fields \
    -e frame.number -e frame.time_relative -e frame.len \
    -e eth.src -e eth.dst -e eth.type \
    -e ip.src -e ip.dst -e udp.srcport -e udp.dstport -e data.data \
    > "$OUT_DIR/packets_full.tsv" 2>>"$LOG" || true
  cp "$OUT_DIR/packets_full.tsv" "$OUT_DIR/packets.tsv" 2>/dev/null || true
else
  log "WARNING: tshark unavailable or PCAP empty; packet TSV not generated"
fi

if [[ -f tools/analyze_eth_packets.py && -s "$OUT_DIR/packets_full.tsv" ]]; then
  python3 tools/analyze_eth_packets.py "$OUT_DIR/packets_full.tsv" \
    --pc-mac "$PC_MAC" --fpga-mac "$FPGA_MAC" \
    --pc-ip "$PC_IP" --fpga-ip "$FPGA_IP" --fpga-port "$FPGA_PORT" \
    --out-dir "$OUT_DIR" > "$OUT_DIR/analysis_stdout.txt" 2> "$OUT_DIR/analysis_stderr.txt" || true
else
  {
    echo "analysis_summary: unavailable"
    echo "reason: tools/analyze_eth_packets.py missing, tshark missing, or packets_full.tsv empty"
    echo "test_rc=${TEST_RC}"
  } > "$OUT_DIR/analysis_summary.txt"
fi

log "Outputs saved in: ${OUT_DIR}"
[[ -f "$OUT_DIR/analysis_summary.txt" ]] && sed 's/^/[summary] /' "$OUT_DIR/analysis_summary.txt" | tee -a "$LOG" || true

if [[ "$OPEN_WIRESHARK" -eq 1 ]] && command -v wireshark >/dev/null 2>&1 && [[ -s "$PCAP" ]]; then
  nohup wireshark "$PCAP" >/dev/null 2>&1 &
fi

exit "$TEST_RC"
