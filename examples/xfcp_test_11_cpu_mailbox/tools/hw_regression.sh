#!/usr/bin/env bash
# hw_regression.sh -- xfcp_test_11_cpu_mailbox HW regresia: UART + UDP
#
# Pouzitie:
#   bash hw_regression.sh [UART_PORT] [FPGA_IP] [REPEAT]
#   make hw-regression
#   make hw-regression UART_PORT=/dev/ttyUSB1 FPGA_IP=192.168.0.5

UART_PORT="${1:-/dev/ttyUSB0}"
FPGA_IP="${2:-192.168.0.5}"
UDP_PORT="${3:-50000}"
REPEAT="${4:-5}"
BAUD="${5:-115200}"

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

sep() { echo ""; echo "=========================================="; }

run_test() {
    local label="$1"; shift
    sep
    echo "  $label"
    sep
    if python3 test_hw.py "$@" --repeat "$REPEAT" --diag; then
        echo ""
        echo "  >>> $label: PASS"
        PASS=$((PASS + 1))
    else
        echo ""
        echo "  >>> $label: FAIL"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "=========================================="
echo "  xfcp_test_11_cpu_mailbox HW regresia"
echo "  UART : $UART_PORT @ $BAUD"
echo "  UDP  : $FPGA_IP:$UDP_PORT"
echo "  Opakovania na slot: $REPEAT"
echo "=========================================="

run_test "UART transport ($UART_PORT @ $BAUD)" \
    --uart "$UART_PORT" --baud "$BAUD" --caps --targets --rw --stream --cpu0 --mem --diag

run_test "UDP  transport ($FPGA_IP:$UDP_PORT)" \
    --udp  "$FPGA_IP:$UDP_PORT" --caps --targets --rw --stream --cpu0 --mem --diag

TOTAL=$((PASS + FAIL))
sep
if [ "$FAIL" -eq 0 ]; then
    echo "  RESULT: $PASS/$TOTAL PASS -- USPECH"
else
    echo "  RESULT: $PASS/$TOTAL PASS, $FAIL/$TOTAL FAIL"
fi
echo "=========================================="

[ "$FAIL" -eq 0 ]
