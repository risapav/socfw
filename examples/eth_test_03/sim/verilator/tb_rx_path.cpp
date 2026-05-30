/**
 * @file tb_rx_path.cpp
 * @brief Verilator testbench for RX parser chain integration test.
 *        gmii_rx_mac → eth_header_parser → ipv4_header_parser → udp_header_parser
 *
 * Tests:
 *   T1: Valid UDP frame ("HELLO") — payload received correctly
 *   T2: Wrong dst_mac — dropped at L2
 *   T3: Wrong dst_ip  — dropped at L3
 *   T4: Wrong UDP dst_port — dropped at L4
 *   T5: Back-to-back valid frames — both payloads received
 *
 * Timing convention:
 *   Inputs are set, then sampled (pre-rising-edge), then clock advances.
 *   This correctly captures combinatorial outputs that depend on state_q
 *   from the previous cycle — matching RTL simulation semantics.
 */

#include "Vrx_path_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <functional>

// --- Compile-time constants matching SV parameters ---
static constexpr uint64_t LOCAL_MAC  = 0x000A3501FEC0ULL;
static constexpr uint32_t LOCAL_IP   = 0xC0A80101U;   // 192.168.1.1
static constexpr uint16_t LOCAL_PORT = 8080;

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
 * Build a complete Ethernet frame:
 *   dst_mac(6) + src_mac(6) + ethertype(2) + IPv4(20) + UDP(8) + payload
 *   + Ethernet padding (to reach 60-byte minimum) + FCS(4)
 *
 * Returns the complete frame including FCS, ready for GMII (without preamble/SFD).
 */
static std::vector<uint8_t> build_frame(
    uint64_t dst_mac, uint64_t src_mac,
    uint32_t src_ip,  uint32_t dst_ip,
    uint16_t src_port, uint16_t dst_port,
    const std::vector<uint8_t>& payload
) {
    std::vector<uint8_t> f;
    f.reserve(64);

    // Ethernet header: dst_mac, src_mac, ethertype=0x0800
    for (int i = 5; i >= 0; i--) f.push_back(static_cast<uint8_t>(dst_mac >> (8 * i)));
    for (int i = 5; i >= 0; i--) f.push_back(static_cast<uint8_t>(src_mac >> (8 * i)));
    f.push_back(0x08); f.push_back(0x00);

    // IPv4 header (20 bytes)
    uint16_t ip_total = static_cast<uint16_t>(28 + payload.size());
    uint16_t udp_len  = static_cast<uint16_t>( 8 + payload.size());
    uint8_t  ip[20]   = {
        0x45, 0x00,
        static_cast<uint8_t>(ip_total >> 8), static_cast<uint8_t>(ip_total),
        0x00, 0x00,         // ID
        0x40, 0x00,         // Flags=DF, frag_offset=0
        0x40, 0x11,         // TTL=64, protocol=UDP
        0x00, 0x00,         // checksum placeholder
        static_cast<uint8_t>(src_ip >> 24), static_cast<uint8_t>(src_ip >> 16),
        static_cast<uint8_t>(src_ip >>  8), static_cast<uint8_t>(src_ip),
        static_cast<uint8_t>(dst_ip >> 24), static_cast<uint8_t>(dst_ip >> 16),
        static_cast<uint8_t>(dst_ip >>  8), static_cast<uint8_t>(dst_ip)
    };
    uint16_t cs = ip_csum(ip, 20);
    ip[10] = static_cast<uint8_t>(cs >> 8);
    ip[11] = static_cast<uint8_t>(cs);
    for (auto b : ip) f.push_back(b);

    // UDP header: src_port, dst_port, length, checksum=0
    auto push16 = [&](uint16_t v) {
        f.push_back(static_cast<uint8_t>(v >> 8));
        f.push_back(static_cast<uint8_t>(v));
    };
    push16(src_port); push16(dst_port); push16(udp_len); push16(0);

    // Payload
    for (auto b : payload) f.push_back(b);

    // Ethernet padding to minimum 60-byte frame (14 eth hdr already included)
    while (f.size() < 60) f.push_back(0x00);

    // FCS (LSB first)
    uint32_t fcs = crc32(f.data(), f.size());
    for (int i = 0; i < 4; i++)
        f.push_back(static_cast<uint8_t>(fcs >> (8 * i)));

    return f;
}

// --- Simulation state ---
static Vrx_path_top* dut;
static int           fails = 0;

// Advance one clock cycle (no sampling).
static void tick() {
    dut->clk_i = 1; dut->eval();
    dut->clk_i = 0; dut->eval();
}

// Reset the DUT.
static void do_reset() {
    dut->rst_ni       = 0;
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
    dut->gmii_rx_er_i = 0;
    dut->udp_tready_i = 1;
    dut->eval();
    for (int i = 0; i < 5; i++) tick();
    dut->rst_ni = 1;
    for (int i = 0; i < 3; i++) tick();
}

/**
 * Send one Ethernet frame over GMII and collect UDP payload output.
 *
 * Sampling convention: outputs are read BEFORE the rising edge, which
 * reflects state_q from the PREVIOUS cycle.  This correctly captures the
 * last payload byte whose state transitions away from ST_PAYLOAD AT the
 * edge (so it would be invisible when sampled after the edge).
 *
 * @param eth_fcs  Complete Ethernet frame including FCS (without preamble).
 * @param tlast_out  Set to true when udp_tlast_o was observed.
 * @return  Captured UDP payload bytes.
 */
static std::vector<uint8_t> send_and_collect(
    const std::vector<uint8_t>& eth_fcs,
    bool& tlast_out
) {
    std::vector<uint8_t> cap;
    tlast_out = false;

    // Sample helper: called before each rising edge.
    auto sample = [&]() {
        if (dut->udp_tvalid_o && dut->udp_tready_i) {
            cap.push_back(dut->udp_tdata_o);
            if (dut->udp_tlast_o) tlast_out = true;
        }
    };

    // One GMII byte: set input → sample → tick.
    auto gmii_byte = [&](uint8_t b, bool dv) {
        dut->gmii_rxd_i   = b;
        dut->gmii_rx_dv_i = dv ? 1 : 0;
        dut->gmii_rx_er_i = 0;
        sample();
        dut->clk_i = 1; dut->eval();
        dut->clk_i = 0; dut->eval();
    };

    // Preamble (7 × 0x55) + SFD (0xD5)
    for (int i = 0; i < 7; i++) gmii_byte(0x55, true);
    gmii_byte(0xD5, true);

    // Ethernet frame + FCS
    for (auto b : eth_fcs) gmii_byte(b, true);

    // End of frame: deassert rxdv, keep clocking to flush pipeline.
    dut->gmii_rxd_i   = 0;
    dut->gmii_rx_dv_i = 0;
    for (int i = 0; i < 80; i++) {
        sample();
        dut->clk_i = 1; dut->eval();
        dut->clk_i = 0; dut->eval();
        if (tlast_out) break;
    }

    // Idle gap between frames.
    for (int i = 0; i < 12; i++) tick();

    return cap;
}

// Assertion helper.
static void check(bool cond, const char* msg) {
    if (!cond) {
        printf("  FAIL: %s\n", msg);
        fails++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vrx_path_top;
    do_reset();

    // ===== T1: Valid UDP frame, "HELLO" payload =====
    {
        const std::vector<uint8_t> pl = {0x48, 0x45, 0x4C, 0x4C, 0x4F}; // HELLO
        auto frame = build_frame(
            LOCAL_MAC, 0xAABBCCDDEEFFULL,
            0x0A000002U, LOCAL_IP,       // 10.0.0.2 → 192.168.1.1
            12345, LOCAL_PORT, pl
        );
        bool tlast;
        auto cap = send_and_collect(frame, tlast);

        bool payload_ok = (cap.size() == 5) &&
                          cap[0]==0x48 && cap[1]==0x45 && cap[2]==0x4C &&
                          cap[3]==0x4C && cap[4]==0x4F;
        check(cap.size() == 5, "T1: captured 5 bytes");
        check(tlast,            "T1: tlast seen");
        check(payload_ok,       "T1: payload = HELLO");
        if (cap.size()==5 && tlast && payload_ok)
            printf("T1  PASS: valid UDP 'HELLO' received correctly\n");
    }

    // ===== T2: Wrong dst_mac → dropped at L2 (eth_header_parser) =====
    {
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto frame = build_frame(
            0x112233445566ULL, 0xAABBCCDDEEFFULL, // wrong dst_mac
            0x0A000002U, LOCAL_IP,
            12345, LOCAL_PORT, pl
        );
        bool tlast;
        auto cap = send_and_collect(frame, tlast);
        check(cap.empty(), "T2: wrong dst_mac → 0 bytes forwarded");
        if (cap.empty()) printf("T2  PASS: wrong dst_mac dropped at L2\n");
    }

    // ===== T3: Wrong dst_ip → dropped at L3 (ipv4_header_parser) =====
    {
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto frame = build_frame(
            LOCAL_MAC, 0xAABBCCDDEEFFULL,
            0x0A000002U, 0x0A000063U,    // 10.0.0.99, not LOCAL_IP
            12345, LOCAL_PORT, pl
        );
        bool tlast;
        auto cap = send_and_collect(frame, tlast);
        check(cap.empty(), "T3: wrong dst_ip → 0 bytes forwarded");
        if (cap.empty()) printf("T3  PASS: wrong dst_ip dropped at L3\n");
    }

    // ===== T4: Wrong UDP dst_port → dropped at L4 (udp_header_parser) =====
    {
        const std::vector<uint8_t> pl = {0xDE, 0xAD};
        auto frame = build_frame(
            LOCAL_MAC, 0xAABBCCDDEEFFULL,
            0x0A000002U, LOCAL_IP,
            12345, 9999,                  // wrong port
            pl
        );
        bool tlast;
        auto cap = send_and_collect(frame, tlast);
        check(cap.empty(), "T4: wrong dst_port → 0 bytes forwarded");
        if (cap.empty()) printf("T4  PASS: wrong dst_port dropped at L4\n");
    }

    // ===== T5: Back-to-back valid frames =====
    {
        const std::vector<uint8_t> pl1 = {0xA1, 0xA2, 0xA3};
        const std::vector<uint8_t> pl2 = {0xB1, 0xB2, 0xB3, 0xB4};
        auto frame1 = build_frame(LOCAL_MAC, 0xAABBCCDDEEFFULL,
                                  0x0A000002U, LOCAL_IP, 12345, LOCAL_PORT, pl1);
        auto frame2 = build_frame(LOCAL_MAC, 0xAABBCCDDEEFFULL,
                                  0x0A000002U, LOCAL_IP, 12345, LOCAL_PORT, pl2);
        bool tl1, tl2;
        auto cap1 = send_and_collect(frame1, tl1);
        auto cap2 = send_and_collect(frame2, tl2);

        bool ok1 = (cap1.size()==3) && tl1 &&
                   cap1[0]==0xA1 && cap1[1]==0xA2 && cap1[2]==0xA3;
        bool ok2 = (cap2.size()==4) && tl2 &&
                   cap2[0]==0xB1 && cap2[1]==0xB2 && cap2[2]==0xB3 && cap2[3]==0xB4;
        check(ok1, "T5: frame1 (3 bytes A1 A2 A3)");
        check(ok2, "T5: frame2 (4 bytes B1 B2 B3 B4)");
        if (ok1 && ok2)
            printf("T5  PASS: back-to-back frames (3+4 bytes)\n");
    }

    // ===== Summary =====
    if (fails == 0)
        printf("tb_rx_path: ALL PASS\n");
    else
        printf("tb_rx_path: %d FAILURES\n", fails);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
