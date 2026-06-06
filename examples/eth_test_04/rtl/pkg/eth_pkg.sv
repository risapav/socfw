/**
 * @file eth_pkg.sv
 * @brief Ethernet library package: protocol constants and metadata struct types.
 * @details Used by all eth_test_04 library modules.
 *   All struct types are packed for FIFO/wire compatibility.
 *   Port lists use flat signals; structs are for internal use and CDC FIFO sizing.
 */
`ifndef ETH_PKG_SV
`define ETH_PKG_SV

package eth_pkg;

  // ---- EtherType constants ----
  localparam logic [15:0] ETH_TYPE_IPV4 = 16'h0800;
  localparam logic [15:0] ETH_TYPE_ARP  = 16'h0806;
  localparam logic [15:0] ETH_TYPE_IPV6 = 16'h86DD;

  // ---- IPv4 protocol field constants ----
  localparam logic [7:0] IP_PROTO_ICMP = 8'h01;
  localparam logic [7:0] IP_PROTO_TCP  = 8'h06;
  localparam logic [7:0] IP_PROTO_UDP  = 8'h11;

  // ---- ICMP type constants ----
  localparam logic [7:0] ICMP_ECHO_REQUEST = 8'h08;
  localparam logic [7:0] ICMP_ECHO_REPLY   = 8'h00;

  // ---- ARP opcodes ----
  localparam logic [15:0] ARP_OP_REQUEST = 16'h0001;
  localparam logic [15:0] ARP_OP_REPLY   = 16'h0002;

  // ---- ARP hardware/protocol type constants ----
  localparam logic [15:0] ARP_HTYPE_ETH  = 16'h0001;
  localparam logic [15:0] ARP_PTYPE_IPV4 = 16'h0800;

  // -------------------------------------------------------------------------
  // Metadata struct types
  // -------------------------------------------------------------------------

  // L2 Ethernet frame metadata (output from eth_rx_mac at tlast)
  typedef struct packed {
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] eth_type;
    logic        fcs_ok;
  } eth_meta_t;  // 113 bits

  // IPv4 header metadata (from ipv4_rx at header completion)
  typedef struct packed {
    logic [31:0] src_ip;
    logic [31:0] dst_ip;
    logic  [7:0] protocol;
    logic  [7:0] ttl;
    logic [15:0] total_len;   // IP total length (header + payload)
    logic [15:0] payload_len; // total_len - 20 (IHL=5 assumed)
  } ipv4_meta_t;  // 112 bits

  // UDP header metadata (from udp_rx at header completion)
  typedef struct packed {
    logic [15:0] src_port;
    logic [15:0] dst_port;
    logic [15:0] payload_len; // UDP length field - 8
  } udp_meta_t;  // 48 bits

  // ARP reply parameters (from arp_rx, consumed by arp_tx)
  // Contains what we need to build a reply: requester's MAC + IP.
  typedef struct packed {
    logic [47:0] requester_mac; // sender MAC from the ARP request
    logic [31:0] requester_ip;  // sender IP from the ARP request
  } arp_reply_t;  // 80 bits

  // Combined UDP echo metadata for CDC (all fields needed to build reply)
  typedef struct packed {
    logic [47:0] dst_mac;     // reply ETH dst  = original src_mac
    logic [47:0] src_mac;     // reply ETH src  = LOCAL_MAC (filled by app)
    logic [31:0] dst_ip;      // reply IP  dst  = original src_ip
    logic [31:0] src_ip;      // reply IP  src  = LOCAL_IP  (filled by app)
    logic [15:0] dst_port;    // reply UDP dst  = original src_port
    logic [15:0] src_port;    // reply UDP src  = original dst_port
    logic [15:0] payload_len;
  } udp_echo_meta_t;  // 208 bits

endpackage

`endif // ETH_PKG_SV
