/**
 * @file tb_echo_path.cpp
 * @brief Verilator testbench for full UDP echo path integration test.
 *        gmii_rx_mac -> ... -> udp_echo_app -> ... -> gmii_tx_mac
 *
 * Tests:
 *   T1: Valid UDP "HELLO" request -> echo response verified byte-by-byte
 *   T2: Wrong dst_mac -> no TX response
 *   T3: Wrong dst_ip  -> no TX response
 *   T4: Back-to-back valid frames -> two echo responses
 *   T5: Zero-payload UDP (udp_len=8) -> header-only echo response (64-byte frame)
 *
 * TX collection: sample_tx() runs every cycle after posedge so that
 * responses starting during GMII RX transmission are captured correctly.
 */

#include "Vecho_path_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

// --- Constants matching SV parameters ---
static constexpr uint64_t LOCAL_MAC  = 0x000A3501FEC0ULL;
static constexpr uint32_t LOCAL_IP   = 0xC0A80101U;   // 192.168.1.1
static constexpr uint16_t LOCAL_PORT = 8080;

static constexpr uint64_t REMOTE_MAC = 0xAABBCCDDEEFFULL;
static constexpr uint32_t REMOTE_IP  = 0x0A000002U;   // 10.0.0.2
static constexpr uint16_t REMOTE_PORT = 12345;

// --- CRC32 IEEE 802.3 (LSB-first, poly 0xEDB88320) ---
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

// --- IPv4 header one's complement checksum ---
static uint16_t ip_csum(const uint8_t* h, size_t n) {
    uint32_t s = 0;
    for (size_t i = 0; i < n; i += 2)
        s += (static_cast<uint32_t>(h[i]) << 8) | h[i + 1];
    s = (s >> 16) + (s & 0xFFFF);
    s += (s >> 16);
    return static_cast<uint16_t>(~s);
}

/**
 * Build a complete Ethernet frame including padding and FCS.
 * Returns frame ready for GMII (without preamble/SFD).
 */
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
static Vecho_path_top* dut;
static int             fails = 0;

// --- Persistent TX frame collector ---
// Accumulates complete TX frames (preamble/SFD stripped) in tx_frames.
// sample_tx() must be called every cycle immediately after posedge eval().
static std::vector<std::vector<uint8_t>> tx_frames;
static std::vector<uint8_t>              tx_current;
static bool                              tx_prev_en  = false;
static bool                              tx_sfd_seen = false;

static void sample_tx() {
    bool    en  = dut->gmii_tx_en_o;
    uint8_t txd = dut->gmii_txd_o;

    if (!tx_prev_en && en) {
        // Rising edge: new TX frame starting.
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
        // Falling edge: frame complete; only store if SFD was seen.
        if (tx_sfd_seen) tx_frames.push_back(tx_current);
        tx_current.clear();
        tx_sfd_seen = false;
    }
    tx_prev_en = en;
}

static void tick() {
    dut->clk_i = 1; dut->eval();
    sample_tx();
    dut->clk_i = 0; dut->eval();
}

static void do_reset() {
    tx_frames.clear();
    tx_current.clear();
    tx_prev_en  = false;
    tx_sfd_seen = false;

    dut->rst_ni       = 0;
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
    dut->gmii_rx_er_i = 0;
    dut->eval();
    for (int i = 0; i < 5; i++) tick();
    dut->rst_ni = 1;
    for (int i = 0; i < 3; i++) tick();
}

/**
 * Send one Ethernet frame over GMII RX.
 * sample_tx() is called each cycle so TX responses starting during
 * this transmission are captured in tx_frames.
 */
static void send_frame(const std::vector<uint8_t>& eth_fcs) {
    auto gmii_byte = [&](uint8_t b, bool dv) {
        dut->gmii_rxd_i   = b;
        dut->gmii_rx_dv_i = dv ? 1 : 0;
        dut->gmii_rx_er_i = 0;
        dut->clk_i = 1; dut->eval();
        sample_tx();
        dut->clk_i = 0; dut->eval();
    };

    for (int i = 0; i < 7; i++) gmii_byte(0x55, true);
    gmii_byte(0xD5, true);
    for (auto b : eth_fcs) gmii_byte(b, true);
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
}

// Clock until tx_frames has at least n entries or max_ticks expires.
static bool wait_frames(size_t n, int max_ticks = 800) {
    for (int i = 0; i < max_ticks && tx_frames.size() < n; i++)
        tick();
    return tx_frames.size() >= n;
}

static void check(bool cond, const char* msg) {
    if (!cond) {
        printf("  FAIL: %s\n", msg);
        fails++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vecho_path_top;
    do_reset();

    // ===== T1: Valid UDP "HELLO" -> echo response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0x48, 0x45, 0x4C, 0x4C, 0x4F}; // HELLO
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        wait_frames(1, 600);

        if (tx_frames.empty()) {
            printf("  FAIL T1: no TX response received\n");
            fails++;
            goto t2;
        }

        {
            const auto& resp = tx_frames[0];
            check(resp.size() >= 64, "T1: response >= 64 bytes");
            if (resp.size() < 14) {
                printf("  FAIL T1: frame too short (%zu bytes)\n", resp.size());
                goto t2;
            }

            uint64_t got_dst = 0, got_src = 0;
            for (int i = 0; i < 6; i++) got_dst = (got_dst << 8) | resp[i];
            for (int i = 0; i < 6; i++) got_src = (got_src << 8) | resp[6 + i];
            check(got_dst == REMOTE_MAC, "T1: echo dst_mac = request src_mac");
            check(got_src == LOCAL_MAC,  "T1: echo src_mac = LOCAL_MAC");
            check(resp[12] == 0x08 && resp[13] == 0x00, "T1: ethertype = 0x0800");

            if (resp.size() >= 34) {
                uint32_t got_sip = ((uint32_t)resp[26] << 24) | ((uint32_t)resp[27] << 16)
                                 | ((uint32_t)resp[28] <<  8) |  (uint32_t)resp[29];
                uint32_t got_dip = ((uint32_t)resp[30] << 24) | ((uint32_t)resp[31] << 16)
                                 | ((uint32_t)resp[32] <<  8) |  (uint32_t)resp[33];
                check(got_sip == LOCAL_IP,  "T1: echo src_ip = LOCAL_IP");
                check(got_dip == REMOTE_IP, "T1: echo dst_ip = REMOTE_IP");
            }

            if (resp.size() >= 42) {
                uint16_t got_sp = (uint16_t)((resp[34] << 8) | resp[35]);
                uint16_t got_dp = (uint16_t)((resp[36] << 8) | resp[37]);
                check(got_sp == LOCAL_PORT,  "T1: echo src_port = LOCAL_PORT");
                check(got_dp == REMOTE_PORT, "T1: echo dst_port = REMOTE_PORT");
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
    for (int i = 0; i < 20; i++) tick();

    // ===== T2: Wrong dst_mac -> no response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto req = build_frame(0x112233445566ULL, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        for (int i = 0; i < 300; i++) tick();
        check(tx_frames.empty(), "T2: wrong dst_mac -> no TX response");
        if (tx_frames.empty()) printf("T2  PASS: wrong dst_mac -> no echo\n");
    }

    for (int i = 0; i < 20; i++) tick();

    // ===== T3: Wrong dst_ip -> no response =====
    {
        tx_frames.clear();
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, 0x0A000063U,
                               REMOTE_PORT, LOCAL_PORT, pl);
        send_frame(req);
        for (int i = 0; i < 300; i++) tick();
        check(tx_frames.empty(), "T3: wrong dst_ip -> no TX response");
        if (tx_frames.empty()) printf("T3  PASS: wrong dst_ip -> no echo\n");
    }

    for (int i = 0; i < 20; i++) tick();

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
        for (int i = 0; i < 12; i++) tick(); // IFG
        send_frame(req2);
        wait_frames(2, 1200);

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

    for (int i = 0; i < 20; i++) tick();

    // ===== T5: Zero-payload UDP -> echo with no payload =====
    {
        tx_frames.clear();
        auto req = build_frame(LOCAL_MAC, REMOTE_MAC, REMOTE_IP, LOCAL_IP,
                               REMOTE_PORT, LOCAL_PORT, {});
        send_frame(req);
        wait_frames(1, 600);

        if (tx_frames.empty()) {
            printf("  FAIL T5: no TX response for zero-payload UDP\n");
            fails++;
            goto summary;
        }

        {
            const auto& resp = tx_frames[0];
            check(resp.size() == 64, "T5: response = 64 bytes (header-only + padding + FCS)");
            if (resp.size() < 42) {
                printf("  FAIL T5: frame too short (%zu bytes)\n", resp.size());
                goto summary;
            }

            uint64_t got_dst = 0, got_src = 0;
            for (int i = 0; i < 6; i++) got_dst = (got_dst << 8) | resp[i];
            for (int i = 0; i < 6; i++) got_src = (got_src << 8) | resp[6 + i];
            check(got_dst == REMOTE_MAC, "T5: echo dst_mac = REMOTE_MAC");
            check(got_src == LOCAL_MAC,  "T5: echo src_mac = LOCAL_MAC");
            check(resp[12] == 0x08 && resp[13] == 0x00, "T5: ethertype = 0x0800");
            // IPv4 total_len = 28 (0x001C)
            check(resp[16] == 0x00 && resp[17] == 0x1C, "T5: IPv4 total_len = 28");

            if (resp.size() >= 34) {
                uint32_t got_sip = ((uint32_t)resp[26] << 24) | ((uint32_t)resp[27] << 16)
                                 | ((uint32_t)resp[28] <<  8) |  (uint32_t)resp[29];
                uint32_t got_dip = ((uint32_t)resp[30] << 24) | ((uint32_t)resp[31] << 16)
                                 | ((uint32_t)resp[32] <<  8) |  (uint32_t)resp[33];
                check(got_sip == LOCAL_IP,  "T5: echo src_ip = LOCAL_IP");
                check(got_dip == REMOTE_IP, "T5: echo dst_ip = REMOTE_IP");
            }

            if (resp.size() >= 42) {
                uint16_t got_sp = (uint16_t)((resp[34] << 8) | resp[35]);
                uint16_t got_dp = (uint16_t)((resp[36] << 8) | resp[37]);
                check(got_sp == LOCAL_PORT,  "T5: echo src_port = LOCAL_PORT");
                check(got_dp == REMOTE_PORT, "T5: echo dst_port = REMOTE_PORT");
                // UDP length field = 8 (header only, no payload)
                check(resp[38] == 0x00 && resp[39] == 0x08, "T5: UDP len = 8");
            }

            if (fails == 0) printf("T5  PASS: zero-payload UDP echo (header-only response)\n");
        }
    }

summary:
    // ===== Summary =====
    if (fails == 0)
        printf("tb_echo_path: ALL PASS\n");
    else
        printf("tb_echo_path: %d FAILURES\n", fails);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
