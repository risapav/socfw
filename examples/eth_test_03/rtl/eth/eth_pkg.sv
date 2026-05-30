/**
 * @file eth_pkg.sv
 * @brief Ethernet library package with common definitions.
 * @details Central package for protocol constants and metadata structures
 * used across L2, L3, and L4 layers.
 */

`ifndef ETH_PKG_SV
`define ETH_PKG_SV


package eth_pkg;

  // --- Protokolové konštanty ---
  localparam logic [15:0] ETH_TYPE_IPV4 = 16'h0800;
  localparam logic [15:0] ETH_TYPE_ARP  = 16'h0806;
  localparam logic [7:0]  IPV4_PROTO_UDP = 8'h11;
  localparam logic [47:0] ETH_BROADCAST_MAC = 48'hFF_FF_FF_FF_FF_FF;

  // --- Dĺžky polí (v bajtoch) ---
  localparam int ETH_MAC_BYTES      = 6;
  localparam int ETH_HEADER_BYTES   = 14;
  localparam int ETH_PREAMBLE_BYTES = 7;
  localparam int ETH_SFD_BYTES      = 1;
  localparam int IPV4_HEADER_BYTES  = 20;
  localparam int UDP_HEADER_BYTES   = 8;
  localparam int ETH_MIN_NO_FCS     = 60;
  localparam int ETH_MIN_WITH_FCS   = 64;
  localparam int ETH_FCS_BYTES      = 4;
  localparam int GMII_IFG_BYTES     = 12;

  // --- Dátové štruktúry ---

  /// Ethernet frame header (14 bytes)
  typedef struct packed {
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] ethertype;
  } eth_hdr_t;

  /// IPv4 header metadata
  typedef struct packed {
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic [15:0] total_len;
    logic [7:0]  protocol;
    logic [15:0] identification;
    logic [7:0]  ttl;
  } ipv4_meta_t;

  /// UDP header metadata
  typedef struct packed {
    logic [15:0] src_port;
    logic [15:0] dst_port;
    logic [15:0] length;
  } udp_meta_t;

  /// Komplexná štruktúra pre UDP paket (používaná v aplikáciách)
  typedef struct packed {
    logic [47:0] src_mac;
    logic [47:0] dst_mac;
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic [15:0] src_port;
    logic [15:0] dst_port;
    logic [15:0] payload_len;
  } udp_packet_meta_t;

endpackage

`endif // ETH_PKG_SV
