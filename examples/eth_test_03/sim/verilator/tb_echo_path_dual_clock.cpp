/**
 * @file tb_echo_path_dual_clock.cpp
 * @brief Dual-clock Verilator testbench for UDP echo path with CDC.
 *        RX clock domain -> async FIFO -> TX clock domain.
 *
 * Clock configuration:
 *   rx_clk: 8.000 ns period (half-period 4000 ps)
 *   tx_clk: 8.013 ns period (half-period 4007 ps, ~0.16% slower)
 *
 * Tests (identical to tb_echo_path.cpp):
 *   T1: Valid UDP "HELLO" -> echo response verified byte-by-byte
 *   T2: Wrong dst_mac -> no TX response
 *   T3: Wrong dst_ip  -> no TX response
 *   T4: Back-to-back valid frames -> two echo responses
 *   T5: Zero-payload UDP (udp_len=8) -> header-only echo response
 *
 * TX sampling runs on every tx_clk posedge via the event-driven step_sim().
 */

#include "Vecho_path_dual_clock_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

// --- Constants matching SV parameters ---
static constexpr uint64_t LOCAL_MAC  = 0x000A3501FEC0ULL;
static constexpr uint32_t LOCAL_IP   = 0xC0A80101U;
static constexpr uint16_t LOCAL_PORT = 8080;

static constexpr uint64_t REMOTE_MAC = 0xAABBCCDDEEFFULL;
static constexpr uint32_t REMOTE_IP  = 0x0A000002U;
static constexpr uint16_t REMOTE_PORT = 12345;

// Half-periods in abstract time units (1 unit ~ 1 ps).
static constexpr uint64_t RX_HALF = 4000;
static constexpr uint64_t TX_HALF = 4007;

// --- CRC32 IEEE 802.3 (LSB-first) ---
static uint32_t crc32(const uint8_t* d, size_t n) {
    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < n; i++)
        for (int b = 0; b < 8; b++) {
            uint32_t fb = (crc ^ (d[i] >> b)) & 1u;
            crc >>= 1;
            if (fb) crc ^= 0xEDB88320U;
        }
    return ~crc;
}

// --- IPv4 one's complement checksum ---
static uint16_t ip_csum(const uint8_t* h, size_t n) {
    uint32_t s = 0;
    for (size_t i = 0; i < n; i += 2)
        s += (static_cast<uint32_t>(h[i]) << 8) | h[i + 1];
    s = (s >> 16) + (s & 0xFFFF);
    s += (s >> 16);
    return static_cast<uint16_t>(~s);
}

static std::vector<uint8_t> build_frame(
    uint64_t dst_mac, uint64_t src_mac,
    uint32_t src_ip,  uint32_t dst_ip,
    uint16_t src_port, uint16_t dst_port,
    const std::vector<uint8_t>& payload
) {
    std::vector<uint8_t> f;
    f.reserve(64);
    for (int i = 5; i >= 0; i--) f.push_back(static_cast<uint8_t>(dst_mac >> (8 * i)));
    for (int i = 5; i >= 0; i--) f.push_back(static_cast<uint8_t>(src_mac >> (8 * i)));
    f.push_back(0x08); f.push_back(0x00);

    uint16_t ip_total = static_cast<uint16_t>(28 + payload.size());
    uint16_t udp_len  = static_cast<uint16_t>( 8 + payload.size());
    uint8_t  ip[20]   = {
        0x45, 0x00,
        static_cast<uint8_t>(ip_total >> 8), static_cast<uint8_t>(ip_total),
        0x00, 0x00, 0x40, 0x00, 0x40, 0x11,
        0x00, 0x00,
        static_cast<uint8_t>(src_ip >> 24), static_cast<uint8_t>(src_ip >> 16),
        static_cast<uint8_t>(src_ip >>  8), static_cast<uint8_t>(src_ip),
        static_cast<uint8_t>(dst_ip >> 24), static_cast<uint8_t>(dst_ip >> 16),
        static_cast<uint8_t>(dst_ip >>  8), static_cast<uint8_t>(dst_ip)
    };
    uint16_t cs = ip_csum(ip, 20);
    ip[10] = static_cast<uint8_t>(cs >> 8);
    ip[11] = static_cast<uint8_t>(cs);
    for (auto b : ip) f.push_back(b);

    auto push16 = [&](uint16_t v) {
        f.push_back(static_cast<uint8_t>(v >> 8));
        f.push_back(static_cast<uint8_t>(v));
    };
    push16(src_port); push16(dst_port); push16(udp_len); push16(0);

    for (auto b : payload) f.push_back(b);
    while (f.size() < 60) f.push_back(0x00);

    uint32_t fcs = crc32(f.data(), f.size());
    for (int i = 0; i < 4; i++)
        f.push_back(static_cast<uint8_t>(fcs >> (8 * i)));
    return f;
}

// --- Simulation state ---
static Vecho_path_dual_clock_top* dut;
static int fails = 0;

// --- Dual-clock time tracking ---
static uint64_t sim_time_ps  = 0;
static uint64_t rx_next_ps   = RX_HALF;   // first rx toggle at t=RX_HALF
static uint64_t tx_next_ps   = TX_HALF;   // first tx toggle at t=TX_HALF (offset)

// --- Persistent TX frame collector (sampling on tx_clk posedge) ---
static std::vector<std::vector<uint8_t>> tx_frames;
static std::vector<uint8_t>              tx_current;
static bool                              tx_prev_en  = false;
static bool                              tx_sfd_seen = false;

static void sample_tx() {
    bool    en  = dut->gmii_tx_en_o;
    uint8_t txd = dut->gmii_txd_o;

    if (!tx_prev_en && en) {
        tx_sfd_seen = false;
        tx_current.clear();
    }
    if (en) {
        if (!tx_sfd_seen) {
            if (txd == 0xD5) tx_sfd_seen = true;
        } else {
            tx_current.push_back(txd);
        }
    }
    if (tx_prev_en && !en) {
        if (tx_sfd_seen) tx_frames.push_back(tx_current);
        tx_current.clear();
        tx_sfd_seen = false;
    }
    tx_prev_en = en;
}

// Advance simulation by one clock event (whichever clock fires next).
// Returns true if rx_clk had a posedge, false otherwise.
// Calls sample_tx() automatically after every tx_clk posedge.
static bool step_sim() {
    uint64_t next = std::min(rx_next_ps, tx_next_ps);
    bool rx_fires = (rx_next_ps == next);
    bool tx_fires = (tx_next_ps == next);

    sim_time_ps = next;

    if (rx_fires) {
        dut->rx_clk_i ^= 1;
        rx_next_ps += RX_HALF;
    }
    if (tx_fires) {
        dut->tx_clk_i ^= 1;
        tx_next_ps += TX_HALF;
    }

    dut->eval();

    bool tx_posedge = tx_fires && (dut->tx_clk_i == 1);
    if (tx_posedge) sample_tx();

    return rx_fires && (dut->rx_clk_i == 1);
}

// Step until the next rx_clk posedge, driving GMII inputs beforehand.
static void rx_posedge_drive(uint8_t rxd, bool dv) {
    dut->gmii_rxd_i   = rxd;
    dut->gmii_rx_dv_i = dv ? 1 : 0;
    dut->gmii_rx_er_i = 0;
    while (!step_sim()) {}   // spin until rx posedge consumed the values
}

static void do_reset() {
    tx_frames.clear();
    tx_current.clear();
    tx_prev_en  = false;
    tx_sfd_seen = false;

    dut->rx_clk_i     = 0;
    dut->tx_clk_i     = 0;
    dut->rst_ni       = 0;
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
    dut->gmii_rx_er_i = 0;
    dut->eval();

    // Hold reset for ~10 rx clock cycles.
    for (int i = 0; i < 20; i++) step_sim();
    dut->rst_ni = 1;
    for (int i = 0; i < 6; i++) step_sim();
}

static void send_frame(const std::vector<uint8_t>& eth_fcs) {
    for (int i = 0; i < 7; i++) rx_posedge_drive(0x55, true);
    rx_posedge_drive(0xD5, true);
    for (auto b : eth_fcs) rx_posedge_drive(b, true);
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
}

// Wait until tx_frames has at least n entries or timeout.
static bool wait_frames(size_t n, uint64_t timeout_ps = 1200000ULL) {
    uint64_t end = sim_time_ps + timeout_ps;
    while (sim_time_ps < end && tx_frames.size() < n)
        step_sim();
    return tx_frames.size() >= n;
}

// Idle gap between tests (in rx clock cycles).
static void idle_rx(int rx_cycles) {
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
    for (int i = 0; i < rx_cycles * 2; i++) step_sim();
}

static void check(bool cond, const char* msg) {
    if (!cond) {
        printf("  FAIL: %s\n", msg);
        fails++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vecho_path_dual_clock_top;
    do_reset();

    // ===== T1: Valid UDP "HELLO" -> echo response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0x48, 0x45, 0x4C, 0x4C, 0x4F}; // HELLO
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        wait_frames(1, 1200000ULL);

        if (tx_frames.empty()) {
            printf("  FAIL T1: no TX response received\n");
            fails++;
            goto t2;
        }
        {
            const auto& resp = tx_frames[0];
            check(resp.size() >= 64, "T1: response >= 64 bytes");
            if (resp.size() < 14) { printf("  FAIL T1: frame too short\n"); goto t2; }

            uint64_t got_dst = 0, got_src = 0;
            for (int i = 0; i < 6; i++) got_dst = (got_dst << 8) | resp[i];
            for (int i = 0; i < 6; i++) got_src = (got_src << 8) | resp[6 + i];
            check(got_dst == REMOTE_MAC, "T1: echo dst_mac = REMOTE_MAC");
            check(got_src == LOCAL_MAC,  "T1: echo src_mac = LOCAL_MAC");
            check(resp[12] == 0x08 && resp[13] == 0x00, "T1: ethertype = 0x0800");

            if (resp.size() >= 34) {
                uint32_t sip = ((uint32_t)resp[26]<<24)|((uint32_t)resp[27]<<16)
                             | ((uint32_t)resp[28]<<8) | (uint32_t)resp[29];
                uint32_t dip = ((uint32_t)resp[30]<<24)|((uint32_t)resp[31]<<16)
                             | ((uint32_t)resp[32]<<8) | (uint32_t)resp[33];
                check(sip == LOCAL_IP,  "T1: echo src_ip = LOCAL_IP");
                check(dip == REMOTE_IP, "T1: echo dst_ip = REMOTE_IP");
            }
            if (resp.size() >= 42) {
                uint16_t sp = (uint16_t)((resp[34]<<8)|resp[35]);
                uint16_t dp = (uint16_t)((resp[36]<<8)|resp[37]);
                check(sp == LOCAL_PORT,  "T1: echo src_port = LOCAL_PORT");
                check(dp == REMOTE_PORT, "T1: echo dst_port = REMOTE_PORT");
            }
            if (resp.size() >= 47) {
                bool ok = resp[42]==0x48 && resp[43]==0x45 && resp[44]==0x4C
                       && resp[45]==0x4C && resp[46]==0x4F;
                check(ok, "T1: echo payload = HELLO");
            }
        }
        if (fails == 0) printf("T1  PASS: UDP HELLO echo response correct\n");
    }

t2:
    idle_rx(20);

    // ===== T2: Wrong dst_mac -> no response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto req = build_frame(0x112233445566ULL, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        idle_rx(300);
        check(tx_frames.empty(), "T2: wrong dst_mac -> no TX response");
        if (tx_frames.empty()) printf("T2  PASS: wrong dst_mac -> no echo\n");
    }

    idle_rx(20);

    // ===== T3: Wrong dst_ip -> no response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, 0x0A000063U,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        idle_rx(300);
        check(tx_frames.empty(), "T3: wrong dst_ip -> no TX response");
        if (tx_frames.empty()) printf("T3  PASS: wrong dst_ip -> no echo\n");
    }

    idle_rx(20);

    // ===== T4: Back-to-back valid frames -> two echo responses =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl1 = {0xA1, 0xA2, 0xA3};
        const std::vector<uint8_t> pl2 = {0xB1, 0xB2, 0xB3, 0xB4};
        auto req1 = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                                REMOTE_PORT, LOCAL_PORT, pl1);
        auto req2 = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                                REMOTE_PORT, LOCAL_PORT, pl2);

        send_frame(req1);
        idle_rx(12);
        send_frame(req2);
        wait_frames(2, 2400000ULL);

        bool ok1 = tx_frames.size() >= 1 && tx_frames[0].size() >= 47 &&
                   tx_frames[0][42]==0xA1 && tx_frames[0][43]==0xA2 &&
                   tx_frames[0][44]==0xA3;
        bool ok2 = tx_frames.size() >= 2 && tx_frames[1].size() >= 48 &&
                   tx_frames[1][42]==0xB1 && tx_frames[1][43]==0xB2 &&
                   tx_frames[1][44]==0xB3 && tx_frames[1][45]==0xB4;
        check(ok1, "T4: frame1 echo payload = A1 A2 A3");
        check(ok2, "T4: frame2 echo payload = B1 B2 B3 B4");
        if (ok1 && ok2) printf("T4  PASS: back-to-back echo (3+4 bytes)\n");
    }

    idle_rx(20);

    // ===== T5: Zero-payload UDP -> header-only echo =====
    {
        tx_frames.clear();
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, {});
        send_frame(req);
        wait_frames(1, 1200000ULL);

        if (tx_frames.empty()) {
            printf("  FAIL T5: no TX response for zero-payload UDP\n");
            fails++;
            goto summary;
        }
        {
            const auto& resp = tx_frames[0];
            check(resp.size() == 64, "T5: response = 64 bytes");
            if (resp.size() < 42) { printf("  FAIL T5: frame too short\n"); goto summary; }

            uint64_t got_dst = 0, got_src = 0;
            for (int i = 0; i < 6; i++) got_dst = (got_dst << 8) | resp[i];
            for (int i = 0; i < 6; i++) got_src = (got_src << 8) | resp[6 + i];
            check(got_dst == REMOTE_MAC, "T5: echo dst_mac = REMOTE_MAC");
            check(got_src == LOCAL_MAC,  "T5: echo src_mac = LOCAL_MAC");
            check(resp[12] == 0x08 && resp[13] == 0x00, "T5: ethertype = 0x0800");
            check(resp[16] == 0x00 && resp[17] == 0x1C, "T5: IPv4 total_len = 28");

            if (resp.size() >= 34) {
                uint32_t sip = ((uint32_t)resp[26]<<24)|((uint32_t)resp[27]<<16)
                             | ((uint32_t)resp[28]<<8) | (uint32_t)resp[29];
                uint32_t dip = ((uint32_t)resp[30]<<24)|((uint32_t)resp[31]<<16)
                             | ((uint32_t)resp[32]<<8) | (uint32_t)resp[33];
                check(sip == LOCAL_IP,  "T5: echo src_ip = LOCAL_IP");
                check(dip == REMOTE_IP, "T5: echo dst_ip = REMOTE_IP");
            }
            if (resp.size() >= 42) {
                uint16_t sp = (uint16_t)((resp[34]<<8)|resp[35]);
                uint16_t dp = (uint16_t)((resp[36]<<8)|resp[37]);
                check(sp == LOCAL_PORT,  "T5: echo src_port = LOCAL_PORT");
                check(dp == REMOTE_PORT, "T5: echo dst_port = REMOTE_PORT");
                check(resp[38]==0x00 && resp[39]==0x08, "T5: UDP len = 8");
            }
            if (fails == 0) printf("T5  PASS: zero-payload UDP echo (header-only)\n");
        }
    }

summary:
    if (fails == 0)
        printf("tb_echo_path_dual_clock: ALL PASS\n");
    else
        printf("tb_echo_path_dual_clock: %d FAILURES\n", fails);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
