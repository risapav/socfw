#!/usr/bin/env bash
# eth_test_03 -- komplexny HW diagnostic
#
# Spusta naraz:
#   1. ARP setup (static entry)
#   2. tcpdump v pozadi (raw Ethernet capture -> /tmp/pcap)
#   3. UART tap v pozadi (prvy TAP_BYTES kazdeho RX frame, volitelny --tap)
#   4. test_fpga.py (UDP echo test)
#   5. Analyza pcap: kolko frames FPGA odoslalo
#   6. Interaktivny J11/J10 LED decode
#
# Pouzitie:
#   ./diag.sh [--tap] [--no-arp] [--ip IP] [--mac MAC] [--port PORT]
#             [--iface IF] [--tap-port /dev/ttyUSBx] [--timeout SEC]

# === Re-exec ako root (potrebne pre tcpdump a ARP) ===
if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

set -uo pipefail

# === Konfig (override cez argumenty) ===
FPGA_IP=192.168.0.2
FPGA_MAC=00:0a:35:01:fe:c0
FPGA_PORT=8080
PC_IFACE=enp0s31f6
TAP_PORT=/dev/ttyUSB0
TAP_BAUD=115200
TAP_BYTES=20
UDP_TIMEOUT=1.5
USE_TAP=0
NO_ARP=0

TS=$(date +%Y%m%d_%H%M%S)
PCAP=/tmp/eth_diag_${TS}.pcap
TAP_LOG=/tmp/eth_tap_${TS}.log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Argumenty ===
while [[ $# -gt 0 ]]; do
  case $1 in
    --tap)       USE_TAP=1 ;;
    --no-arp)    NO_ARP=1 ;;
    --ip)        FPGA_IP="$2";     shift ;;
    --mac)       FPGA_MAC="$2";    shift ;;
    --port)      FPGA_PORT="$2";   shift ;;
    --iface)     PC_IFACE="$2";    shift ;;
    --tap-port)  TAP_PORT="$2";    shift ;;
    --timeout)   UDP_TIMEOUT="$2"; shift ;;
    --pcap)      PCAP="$2";        shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "Nezname: $1"; exit 1 ;;
  esac
  shift
done

# === Farby ===
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; CYN='\033[0;36m'; RST='\033[0m'
ok()   { echo -e "  ${GRN}OK${RST}  $*"; }
fail() { echo -e "  ${RED}!!${RST}  $*"; }
info() { echo -e "  ${CYN}--${RST}  $*"; }
warn() { echo -e "  ${YLW}??${RST}  $*"; }

# === Cleanup ===
DUMP_PID=""
TAP_PID=""
cleanup() {
  [[ -n "$DUMP_PID" ]] && { kill "$DUMP_PID" 2>/dev/null; wait "$DUMP_PID" 2>/dev/null || true; }
  [[ -n "$TAP_PID"  ]] && { kill "$TAP_PID"  2>/dev/null; wait "$TAP_PID"  2>/dev/null || true; }
}
trap cleanup EXIT

# ============================================================
echo ""
echo -e "${CYN}╔══════════════════════════════════════════════════════════╗"
echo    "║         eth_test_03  HW diagnostic                      ║"
echo -e "╚══════════════════════════════════════════════════════════╝${RST}"
echo -e "  FPGA: ${FPGA_IP}  (${FPGA_MAC})  port=${FPGA_PORT}"
echo -e "  PC  : ${PC_IFACE}  pcap=${PCAP}"
echo ""

# ============================================================
# 1. ARP
# ============================================================
echo -e "${CYN}[1/5] ARP setup${RST}"
if [[ $NO_ARP -eq 0 ]]; then
  if ip neigh replace "$FPGA_IP" lladdr "$FPGA_MAC" nud permanent dev "$PC_IFACE"; then
    ok "static ARP: $FPGA_IP -> $FPGA_MAC  dev $PC_IFACE"
  else
    warn "ARP setup zlyhalo"
  fi
else
  CURR=$(ip neigh show dev "$PC_IFACE" 2>/dev/null | grep "$FPGA_IP" || true)
  if [[ -n "$CURR" ]]; then
    ok "ARP preskocene -- existujuci zaznam: $CURR"
  else
    warn "ARP preskocene ale zaznam neexistuje -- pakety mozno nedorazia"
  fi
fi

# ============================================================
# 1b. Link speed / status
# ============================================================
echo ""
echo -e "${CYN}[1b] Link speed${RST}"
if command -v ethtool &>/dev/null; then
  LINK_SPEED=$(ethtool "$PC_IFACE" 2>/dev/null | grep -i "Speed:"        | awk '{print $2}' || echo "?")
  LINK_DUPLEX=$(ethtool "$PC_IFACE" 2>/dev/null | grep -i "Duplex:"      | awk '{print $2}' || echo "?")
  LINK_UP=$(ethtool "$PC_IFACE" 2>/dev/null     | grep -i "Link detected:" | awk '{print $3}' || echo "?")
  echo "  Link: $LINK_UP   Speed: $LINK_SPEED   Duplex: $LINK_DUPLEX"
  if [[ "$LINK_UP" != "yes" ]]; then
    fail "LINK DOWN -- kabel neprepojen alebo PHY problem"
  elif [[ "$LINK_SPEED" == "1000Mb/s" ]]; then
    ok "1 Gbps link -- GMII 125 MHz je spravny"
  elif [[ "$LINK_SPEED" == "100Mb/s" ]]; then
    fail "100 Mbps link! FPGA GMII TX (125 MHz) nebude fungovat!"
    warn "  PHY bezi na 25 MHz MII a ignoruje GTxCLK (125 MHz)."
    warn "  -> Skontroluj kabel (Cat5e/Cat6), prepinac, alebo vynuc 1Gbps:"
    warn "     ethtool -s $PC_IFACE speed 1000 duplex full autoneg off"
  else
    warn "Rychlost: $LINK_SPEED -- neznamy stav"
  fi
  # Record NIC CRC/FCS error baseline before test
  NIC_CRC_BEFORE=$(ethtool -S "$PC_IFACE" 2>/dev/null \
    | grep -iE "crc|fcs|bad|error" | grep -v "^$" || echo "")
else
  warn "ethtool nie je k dispozicii"
  NIC_CRC_BEFORE=""
fi

# ============================================================
# 2. tcpdump
# ============================================================
echo ""
echo -e "${CYN}[2/5] tcpdump${RST}"
tcpdump -i "$PC_IFACE" -w "$PCAP" \
    "ether host $FPGA_MAC or udp port $FPGA_PORT" 2>/dev/null &
DUMP_PID=$!
sleep 0.4
if [[ -f "$PCAP" ]] && kill -0 "$DUMP_PID" 2>/dev/null; then
  ok "tcpdump bezi (PID=$DUMP_PID) -> $PCAP"
else
  fail "tcpdump sa nepodarilo spustit alebo nevytvoril pcap"
  DUMP_PID=""
fi

# ============================================================
# 3. UART tap
# ============================================================
echo ""
echo -e "${CYN}[3/5] UART tap${RST}"
if [[ $USE_TAP -eq 1 ]]; then
  if [[ -e "$TAP_PORT" ]]; then
    python3 "$SCRIPT_DIR/tools/read_tap.py" \
        --port "$TAP_PORT" --baud $TAP_BAUD \
        --count $TAP_BYTES --frames 0 > "$TAP_LOG" 2>&1 &
    TAP_PID=$!
    sleep 0.3
    if kill -0 "$TAP_PID" 2>/dev/null; then
      ok "UART tap bezi (PID=$TAP_PID) -> $TAP_LOG"
    else
      warn "UART tap sa ukoncil hned (problem s portom?)"
      TAP_PID=""
    fi
  else
    warn "$TAP_PORT nenajdeny -- UART tap preskoceny"
  fi
else
  info "UART tap vypnuty (pridaj --tap na zapnutie)"
fi

# ============================================================
# 4. UDP echo test
# ============================================================
echo ""
echo -e "${CYN}[4/5] UDP echo test${RST}"
echo "  ────────────────────────────────────────────────────"
python3 "$SCRIPT_DIR/test_fpga.py" \
    --ip "$FPGA_IP" --port "$FPGA_PORT" \
    --mac "$FPGA_MAC" --iface "$PC_IFACE" \
    --no-arp --timeout "$UDP_TIMEOUT" || true
echo "  ────────────────────────────────────────────────────"

echo ""
info "Cakam 1s na posledne oneskorene odpovede..."
sleep 1.0

# === Zastavenie pozadia ===
[[ -n "$DUMP_PID" ]] && { kill "$DUMP_PID" 2>/dev/null; wait "$DUMP_PID" 2>/dev/null || true; DUMP_PID=""; }
[[ -n "$TAP_PID"  ]] && { kill "$TAP_PID"  2>/dev/null; wait "$TAP_PID"  2>/dev/null || true; TAP_PID=""; }
sleep 0.2

# ============================================================
# 5. Analyza pcap
# ============================================================
echo ""
echo -e "${CYN}[5/5] Analyza pcap${RST}"

if [[ ! -f "$PCAP" ]]; then
  warn "pcap subor neexistuje -- tcpdump mozno nezachytil nic"
else
  TOTAL=$(tcpdump -r "$PCAP" -n 2>/dev/null | wc -l)
  FPGA_MAC_LC=$(echo "$FPGA_MAC" | tr '[:upper:]' '[:lower:]')
  FROM_FPGA=$(tcpdump -r "$PCAP" -e -n 2>/dev/null | grep -ic "${FPGA_MAC_LC} >" || true)

  echo ""
  echo "  Vsetky zachytene frames   : $TOTAL"
  echo "  Frames obsahujuce FPGA MAC: $FROM_FPGA"
  echo ""

  if [[ $FROM_FPGA -gt 0 ]]; then
    echo -e "  ${GRN}>>> FPGA odosielalo! Prvy frame od FPGA:${RST}"
    echo ""
    tcpdump -r "$PCAP" -e -n -XX 2>/dev/null \
      | grep -A 20 "${FPGA_MAC_LC}" \
      | head -25
    echo ""
    echo -e "  ${GRN}FPGA TX FUNGUJE -- GMII->PHY->wire OK${RST}"
    echo "  Mozne zvysne problemy: nespravne IP/port/MAC v echoi, PC odmietol paket"
  else
    echo -e "  ${RED}>>> ZIADNE frames od FPGA na wire!${RST}"

    # Check NIC CRC/FCS error counters -- did FPGA transmit frames with bad FCS?
    if [[ -n "${NIC_CRC_BEFORE:-}" ]] && command -v ethtool &>/dev/null; then
      NIC_CRC_AFTER=$(ethtool -S "$PC_IFACE" 2>/dev/null \
        | grep -iE "crc|fcs|bad|error" | grep -v "^$" || echo "")
      echo ""
      if [[ "$NIC_CRC_BEFORE" != "$NIC_CRC_AFTER" ]]; then
        warn "NIC CRC/FCS chyby sa ZMENILI pocas testu!"
        warn "  -> FPGA pravdepodobne vysiela framy s chybnym FCS (CRC bug)"
        warn "  -> NIC zahodil framy pred tcpdump (HW drop)"
        echo "  Rozdiel (< pred, > po):"
        diff <(echo "$NIC_CRC_BEFORE") <(echo "$NIC_CRC_AFTER") || true
      else
        info "NIC CRC/FCS chyby: bez zmeny pocas testu"
        info "  -> FPGA zrejme vobec nič nevyslal na fyzicku linku"
      fi
      echo ""
    fi

    echo "  Mozne priciny:"
    echo "    - gmii_tx_mac sa neaktivoval (skontroluj J11 bit7)"
    echo "    - TX clock (PLL) nefunguje"
    echo "    - PHY ignoruje GMII TX (PHYRSTB stale low?)"
    echo "    - Link speed nie je 1 Gbps (vid sekciu 1b)"
    echo "    - Fyzicke spojenie (kabel, RJ45)"
  fi

  echo ""
  info "Plna analyza: tcpdump -r $PCAP -e -n -XX"
fi

# === UART tap log ===
if [[ -f "$TAP_LOG" && -s "$TAP_LOG" ]]; then
  echo ""
  echo -e "${CYN}=== UART tap output ===${RST}"
  cat "$TAP_LOG"
fi

# ============================================================
# LED decode
# ============================================================
echo ""
echo -e "${CYN}╔══════════════════════════════════════════════════════════╗"
echo    "║              J11 / J10  LED decode                      ║"
echo -e "╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
echo "  Pozri sa na PMOD_J11_LED8 a PMOD_J10_LED8 na FPGA boarde."
echo "  Citaj od bitu 7 (pin1, lavy) po bit 0 (pin8, pravy)."
echo "  s = LED ON  = logicka 0   |   n = LED OFF = logicka 1"
echo ""

decode_j11() {
  local bits="${1,,}"
  if [[ ${#bits} -ne 8 ]]; then
    warn "Musi byt presne 8 znakov (napr. 'snnnnsss')"; return
  fi

  # char index 0 = bit7 (MSB), char index 7 = bit0 (LSB)
  local -a NAMES=(
    "latch_tx_busy_q   "  # bit7  [0]
    "latch_meta_wr_q   "  # bit6  [1]
    "latch_txb_fire_q  "  # bit5  [2]
    "latch_tx_meta_q   "  # bit4  [3]
    "latch_rx_meta_q   "  # bit3  [4]
    "latch_udp_tvalid_q"  # bit2  [5]
    "latch_udp_tlast_q "  # bit1  [6]
    "tx_meta_valid     "  # bit0  [7]
  )
  local -a DESCS=(
    "gmii_tx_mac bol aktivny -- GMII TX na drate     [TX-STICKY]"
    "meta FIFO write prebehol -- CDC TX triggered     [RX-STICKY]"
    "TX builder vypalil aspon 1 byte                 [RX-STICKY]"
    "echo_app dokoncil RX, vstupil do TX_META        [RX-STICKY]"
    "UDP meta OK -- parsery funguju                  [RX-STICKY]"
    "udp_parser emitoval aspon 1 payload byte        [RX-STICKY]"
    "udp_parser vypalil tlast (cely payload)         [RX-STICKY]"
    "echo_app je teraz v ST_TX_META                  [RX-LIVE]"
  )

  echo "  J11 = $bits"
  echo ""

  local i
  for i in 0 1 2 3 4 5 6 7; do
    local bitnum=$((7 - i))
    local ch="${bits:$i:1}"
    local val=0
    [[ "$ch" == "n" ]] && val=1
    local sym color
    if [[ $val -eq 1 ]]; then
      sym="n=1"; color="$GRN"
    else
      sym="s=0"; color="$RED"
    fi
    [[ $i -ge 7 ]] && color="$YLW"  # bit0 is live (not sticky) -- yellow
    printf "  bit%d [%b%s%b]  %s  %s\n" \
      "$bitnum" "$color" "$sym" "$RST" "${NAMES[$i]}" "${DESCS[$i]}"
  done

  echo ""
  echo "  Diagnoza:"
  local c0="${bits:0:1}" c1="${bits:1:1}" c2="${bits:2:1}"
  local c3="${bits:3:1}" c4="${bits:4:1}" c5="${bits:5:1}"
  local c6="${bits:6:1}"

  if   [[ "$c4" == "s" ]]; then
    fail "latch_rx_meta=0 -- parsery NIKDY nezostavili UDP meta"
    warn "  -> Skontroluj GMII RX signaly, preamble, MAC/IP filter"
  elif [[ "$c5" == "s" ]]; then
    fail "latch_udp_tvalid=0 -- udp_parser NIKDY neemitoval payload byte"
    warn "  -> Skontroluj udp_header_parser ST_PAYLOAD, ip_tvalid,"
    warn "     payload_len, alebo ip/port filter (promiscuous=0?)"
  elif [[ "$c6" == "s" ]]; then
    fail "latch_udp_tlast=0 -- udp_parser NIKDY nevypalil tlast"
    warn "  -> payload_cnt sa NIKDY nedostalo na payload_len-1"
    warn "  -> Mozne priciny: payload_len chybny (prilis velky),"
    warn "     ip_tvalid=0 pocas ST_PAYLOAD, alebo backpressure"
  elif [[ "$c3" == "s" ]]; then
    fail "latch_tx_meta=0 -- echo_app nevidel tlast (tlast prisiel ale echo ignoroval?)"
    warn "  -> udp_tlast prisiel (bit1=n) ale echo_app nereagoval"
    warn "  -> Skontroluj echo_app FSM: tready=0 ked prisiel tlast?"
  elif [[ "$c2" == "s" ]]; then
    fail "latch_txb_fire=0 -- TX builder NIKDY nevypalil byte"
    warn "  -> echo_app->txb handshake alebo meta latching problem"
  elif [[ "$c1" == "s" ]]; then
    fail "latch_meta_wr=0 -- meta FIFO NIKDY nebol zapisany"
    warn "  -> commit_pending problem alebo meta FIFO plny"
  elif [[ "$c0" == "s" ]]; then
    fail "latch_tx_busy=0 -- gmii_tx_mac sa NIKDY neaktivoval!"
    warn "  -> TXC FSM nevidel meta_rd_valid z CDC async_fifo"
    warn "  -> Mozne priciny: TX clock (PLL) nefunguje,"
    warn "     async_fifo CDC nepropaguje data do TX domeny,"
    warn "     alebo TXC FSM stuck (skontroluj txc_state)"
  else
    ok  "CELA PIPELINE prebehla -- FPGA odoslal GMII frames!"
    ok  "  -> Skontroluj pcap vysie ci frames prisli na PC"
    info "  -> Ak pcap prazdny: PHY nefunguje alebo fyzicke spojenie"
    info "  -> Ak pcap ma frames: skontroluj dst_mac/ip v odpovedi"
  fi
}

decode_j10() {
  local bits="${1,,}"
  [[ ${#bits} -ne 8 ]] && { warn "Musi byt presne 8 znakov"; return; }
  local val=0
  local i
  for i in 0 1 2 3 4 5 6 7; do
    [[ "${bits:$i:1}" == "n" ]] && val=$((val | (1 << (7 - i))))
  done
  printf "  J10 = %s  (hex: 0x%02X)\n" "$bits" "$val"
  echo "  Obsah (priorita): txb_tdata > pkt_rd_data > dbg_dst_mac[15:8]"
  echo "  Idle pre FPGA_MAC 00:0a:35:01:FE:c0 => byte[15:8]=0xFE => 'nnnnnnns'"
  if [[ $val -eq 0xFE ]]; then
    ok "J10=0xFE -- DST_MAC byte4 spravny, eth_header_parser videl nas MAC"
  elif [[ $val -eq 0 ]]; then
    warn "J10=0x00 -- buď ziadny frame neprisiel, alebo DST_MAC[15:8]=0x00"
  else
    printf "  ?? J10=0x%02X -- ine ako ocakavane 0xFE\n" "$val"
  fi
}

read -rp "  Zadaj J11 stav (8 znakov, napr. 'snnnnsss', Enter=preskocit): " J11_INPUT || J11_INPUT=""
echo ""
if [[ -n "$J11_INPUT" ]]; then
  decode_j11 "$J11_INPUT"
fi

echo ""
read -rp "  Zadaj J10 stav (8 znakov, Enter=preskocit): " J10_INPUT || J10_INPUT=""
echo ""
if [[ -n "$J10_INPUT" ]]; then
  decode_j10 "$J10_INPUT"
fi

echo ""
echo -e "${CYN}=== Hotovo ===${RST}"
echo ""
