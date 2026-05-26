/**
 * @file        eth_udp_echo_test.sv
 * @brief       UDP echo test peripheral with AXI-Lite diagnostic registers.
 * @details     Receives UDP payload and echoes it back to the original sender.
 *              Provides AXI-Lite registers for configuration and diagnostics.
 *              Designed to sit behind a UDP/IP stack (payload stream interface).
 *
 *              Register map (byte offset from base):
 *                0x00 RO  ID               = 0x4554485F ("ETH_")
 *                0x04 RO  VERSION          = 0x00010000
 *                0x08 RW  CONTROL          bit0=enable bit1=echo_en bit2=promiscuous
 *                0x0C RO  STATUS           bit0=link_up bit1=enabled bit2=rx_active
 *                                          bit3=tx_active bit5=udp_ready bit6=busy
 *                0x10 RW  LOCAL_IP
 *                0x14 RW  UDP_PORT         [15:0]
 *                0x18 RO  RX_FRAME_COUNT
 *                0x1C RO  TX_FRAME_COUNT
 *                0x20 RO  RX_BYTE_COUNT
 *                0x24 RO  TX_BYTE_COUNT
 *                0x28 RO  RX_DROP_COUNT
 *                0x2C RO  RX_ERROR_COUNT
 *                0x30 RO  TX_ERROR_COUNT
 *                0x34 RO  LAST_SRC_IP
 *                0x38 RO  LAST_SRC_PORT    [15:0]
 *                0x3C RO  LAST_DST_PORT    [15:0]
 *                0x40 RO  LAST_PAYLOAD_LEN [15:0]
 *                0x44 RO  LAST_ERROR       0=OK 2=TOO_LONG
 *                0x48 WO  CLEAR_COUNTERS   (write any value to clear)
 *
 * @param DEFAULT_IP         Reset value for LOCAL_IP register (192.168.1.50)
 * @param DEFAULT_UDP_PORT   Reset value for UDP_PORT register (50000)
 * @param MAX_PAYLOAD_BYTES  Echo buffer depth; must be a power of 2, max 32767
 */
`ifndef ETH_UDP_ECHO_TEST_SV
`define ETH_UDP_ECHO_TEST_SV

`default_nettype none

module eth_udp_echo_test #(
  parameter logic [31:0] DEFAULT_IP        = 32'hC0A8_0132, // 192.168.1.50
  parameter logic [15:0] DEFAULT_UDP_PORT  = 16'd50000,
  parameter int          MAX_PAYLOAD_BYTES = 512            // must be power of 2
)(
  input  logic       clk_i,
  input  logic       rst_ni,
  axi4lite_if.slave  s_axil,

  // UDP RX metadata (from UDP/IP stack)
  input  logic        udp_rx_meta_valid_i,
  output logic        udp_rx_meta_ready_o,
  input  logic [31:0] udp_rx_src_ip_i,
  input  logic [31:0] udp_rx_dst_ip_i,
  input  logic [15:0] udp_rx_src_port_i,
  input  logic [15:0] udp_rx_dst_port_i,
  input  logic [15:0] udp_rx_length_i,

  // UDP RX payload stream
  input  logic        udp_rx_valid_i,
  output logic        udp_rx_ready_o,
  input  logic [7:0]  udp_rx_data_i,
  input  logic        udp_rx_last_i,

  // UDP TX metadata (to UDP/IP stack)
  output logic        udp_tx_meta_valid_o,
  input  logic        udp_tx_meta_ready_i,
  output logic [31:0] udp_tx_dst_ip_o,
  output logic [15:0] udp_tx_dst_port_o,
  output logic [15:0] udp_tx_src_port_o,
  output logic [15:0] udp_tx_length_o,

  // UDP TX payload stream
  output logic        udp_tx_valid_o,
  input  logic        udp_tx_ready_i,
  output logic [7:0]  udp_tx_data_o,
  output logic        udp_tx_last_o,

  // PHY link status
  input  logic        link_up_i,

  // Interrupt (not implemented in v1)
  output logic        irq_o
);
  import axi_pkg::*;

  // ---------------------------------------------------------------------------
  // Register file: 19 x 32-bit registers
  // ---------------------------------------------------------------------------
  localparam int NUM_REGS = 19;

  // REG_TYPES packed [NUM_REGS*2-1:0]: MSB = reg18, LSB = reg0
  localparam [NUM_REGS*2-1:0] REG_TYPES = {
    2'(AXIL_PULSE),  // reg18 0x48 CLEAR_COUNTERS
    2'(AXIL_RO),     // reg17 0x44 LAST_ERROR
    2'(AXIL_RO),     // reg16 0x40 LAST_PAYLOAD_LEN
    2'(AXIL_RO),     // reg15 0x3C LAST_DST_PORT
    2'(AXIL_RO),     // reg14 0x38 LAST_SRC_PORT
    2'(AXIL_RO),     // reg13 0x34 LAST_SRC_IP
    2'(AXIL_RO),     // reg12 0x30 TX_ERROR_COUNT
    2'(AXIL_RO),     // reg11 0x2C RX_ERROR_COUNT
    2'(AXIL_RO),     // reg10 0x28 RX_DROP_COUNT
    2'(AXIL_RO),     // reg9  0x24 TX_BYTE_COUNT
    2'(AXIL_RO),     // reg8  0x20 RX_BYTE_COUNT
    2'(AXIL_RO),     // reg7  0x1C TX_FRAME_COUNT
    2'(AXIL_RO),     // reg6  0x18 RX_FRAME_COUNT
    2'(AXIL_RW),     // reg5  0x14 UDP_PORT
    2'(AXIL_RW),     // reg4  0x10 LOCAL_IP
    2'(AXIL_RO),     // reg3  0x0C STATUS
    2'(AXIL_RW),     // reg2  0x08 CONTROL
    2'(AXIL_RO),     // reg1  0x04 VERSION
    2'(AXIL_RO)      // reg0  0x00 ID
  };

  // RESET_VALS packed [NUM_REGS*32-1:0]: MSB = reg18, LSB = reg0
  localparam [NUM_REGS*32-1:0] RESET_VALS = {
    32'h0,                      // reg18 CLEAR_COUNTERS
    32'h0,                      // reg17 LAST_ERROR
    32'h0,                      // reg16 LAST_PAYLOAD_LEN
    32'h0,                      // reg15 LAST_DST_PORT
    32'h0,                      // reg14 LAST_SRC_PORT
    32'h0,                      // reg13 LAST_SRC_IP
    32'h0,                      // reg12 TX_ERROR_COUNT
    32'h0,                      // reg11 RX_ERROR_COUNT
    32'h0,                      // reg10 RX_DROP_COUNT
    32'h0,                      // reg9  TX_BYTE_COUNT
    32'h0,                      // reg8  RX_BYTE_COUNT
    32'h0,                      // reg7  TX_FRAME_COUNT
    32'h0,                      // reg6  RX_FRAME_COUNT
    {16'd0, DEFAULT_UDP_PORT},  // reg5  UDP_PORT
    DEFAULT_IP,                 // reg4  LOCAL_IP
    32'h0,                      // reg3  STATUS (RO, driven from HW)
    32'h3,                      // reg2  CONTROL: enable=1, echo_en=1
    32'h0,                      // reg1  VERSION (RO, driven from HW)
    32'h0                       // reg0  ID (RO, driven from HW)
  };

  logic [NUM_REGS*32-1:0] hw_rdata_w;
  logic [NUM_REGS*32-1:0] hw_wdata_w;
  logic [NUM_REGS-1:0]    hw_we_w;

  axil_regfile #(
    .NUM_REGS  (NUM_REGS),
    .REG_TYPES (REG_TYPES),
    .RESET_VALS(RESET_VALS)
  ) u_regfile (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .s_axil     (s_axil),
    .hw_rdata_i (hw_rdata_w),
    .hw_wdata_o (hw_wdata_w),
    .hw_we_o    (hw_we_w)
  );

  // Config extracted from RW registers
  wire        en_w      = hw_wdata_w[2*32 + 0];  // CONTROL bit0
  wire        echo_en_w = hw_wdata_w[2*32 + 1];  // CONTROL bit1
  wire        promis_w  = hw_wdata_w[2*32 + 2];  // CONTROL bit2
  wire [31:0] local_ip_w  = hw_wdata_w[4*32 +: 32];
  wire [15:0] udp_port_w  = hw_wdata_w[5*32 +: 16];
  wire        clr_w       = hw_we_w[18];  // CLEAR_COUNTERS pulse

  // ---------------------------------------------------------------------------
  // Echo FSM
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE      = 3'd0,
    ST_DROP      = 3'd1,
    ST_RECV      = 3'd2,
    ST_SEND_META = 3'd3,
    ST_SEND_PAY  = 3'd4,
    ST_DONE      = 3'd5
  } fsm_state_e;

  fsm_state_e fsm_r;

  // Echo buffer (distributed RAM for MAX_PAYLOAD_BYTES <= 1024)
  localparam int ABITS = $clog2(MAX_PAYLOAD_BYTES);
  (* ramstyle = "logic" *)
  logic [7:0]       payload_mem_r [0:MAX_PAYLOAD_BYTES-1];
  logic [ABITS-1:0] wr_ptr_r;   // number of bytes written
  logic [ABITS-1:0] rd_ptr_r;   // current read index
  logic [15:0]      pay_len_r;  // received payload length (saturating)
  logic             overflow_r; // packet exceeded buffer
  logic             drop_r;     // this DONE resulted from a DROP

  // Captured echo destination
  logic [31:0] echo_dst_ip_r;
  logic [15:0] echo_dst_port_r;

  // ---------------------------------------------------------------------------
  // Diagnostic counters (live, saturating 32-bit)
  // ---------------------------------------------------------------------------
  logic [31:0] rx_frame_cnt_r, tx_frame_cnt_r;
  logic [31:0] rx_byte_cnt_r,  tx_byte_cnt_r;
  logic [31:0] rx_drop_cnt_r,  rx_err_cnt_r, tx_err_cnt_r;
  logic [31:0] last_src_ip_r,  last_src_port_r, last_dst_port_r;
  logic [31:0] last_plen_r,    last_err_r;

  function automatic logic [31:0] sat_inc(input logic [31:0] v);
    return (v == 32'hFFFF_FFFF) ? v : v + 32'd1;
  endfunction

  // ---------------------------------------------------------------------------
  // FSM + buffer + counters (combined for atomicity)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fsm_r           <= ST_IDLE;
      wr_ptr_r        <= '0;
      rd_ptr_r        <= '0;
      pay_len_r       <= 16'd0;
      overflow_r      <= 1'b0;
      drop_r          <= 1'b0;
      echo_dst_ip_r   <= 32'd0;
      echo_dst_port_r <= 16'd0;
      rx_frame_cnt_r  <= 32'd0;  tx_frame_cnt_r <= 32'd0;
      rx_byte_cnt_r   <= 32'd0;  tx_byte_cnt_r  <= 32'd0;
      rx_drop_cnt_r   <= 32'd0;  rx_err_cnt_r   <= 32'd0;  tx_err_cnt_r <= 32'd0;
      last_src_ip_r   <= 32'd0;  last_src_port_r <= 32'd0; last_dst_port_r <= 32'd0;
      last_plen_r     <= 32'd0;  last_err_r      <= 32'd0;
    end else if (clr_w) begin
      rx_frame_cnt_r  <= 32'd0;  tx_frame_cnt_r <= 32'd0;
      rx_byte_cnt_r   <= 32'd0;  tx_byte_cnt_r  <= 32'd0;
      rx_drop_cnt_r   <= 32'd0;  rx_err_cnt_r   <= 32'd0;  tx_err_cnt_r <= 32'd0;
      last_src_ip_r   <= 32'd0;  last_src_port_r <= 32'd0; last_dst_port_r <= 32'd0;
      last_plen_r     <= 32'd0;  last_err_r      <= 32'd0;
    end else begin
      case (fsm_r)

        // -- Accept metadata, decide echo or drop --
        ST_IDLE: begin
          if (udp_rx_meta_valid_i) begin
            last_src_ip_r   <= udp_rx_src_ip_i;
            last_src_port_r <= {16'd0, udp_rx_src_port_i};
            last_dst_port_r <= {16'd0, udp_rx_dst_port_i};
            if (!en_w || !echo_en_w || (!promis_w && udp_rx_dst_port_i != udp_port_w)) begin
              drop_r <= 1'b1;
              fsm_r  <= ST_DROP;
            end else begin
              echo_dst_ip_r   <= udp_rx_src_ip_i;
              echo_dst_port_r <= udp_rx_src_port_i;
              wr_ptr_r        <= '0;
              pay_len_r       <= 16'd0;
              overflow_r      <= 1'b0;
              drop_r          <= 1'b0;
              fsm_r           <= ST_RECV;
            end
          end
        end

        // -- Drain payload without storing --
        ST_DROP: begin
          if (udp_rx_valid_i && udp_rx_last_i)
            fsm_r <= ST_DONE;
        end

        // -- Buffer incoming payload --
        ST_RECV: begin
          if (udp_rx_valid_i) begin
            if (!overflow_r) begin
              payload_mem_r[wr_ptr_r] <= udp_rx_data_i;
              // &wr_ptr_r is MAX-1 only when MAX_PAYLOAD_BYTES is a power of 2
              if (&wr_ptr_r)
                overflow_r <= 1'b1;
              else
                wr_ptr_r <= wr_ptr_r + 1'b1;
            end
            if (pay_len_r != 16'hFFFF) pay_len_r <= pay_len_r + 16'd1;
            if (rx_byte_cnt_r != 32'hFFFF_FFFF) rx_byte_cnt_r <= rx_byte_cnt_r + 32'd1;
            if (udp_rx_last_i) begin
              last_plen_r <= {16'd0, pay_len_r + 16'd1}; // +1: current byte not yet reflected
              if (overflow_r) begin
                rx_err_cnt_r <= sat_inc(rx_err_cnt_r);
                last_err_r   <= 32'd2;  // TOO_LONG
                fsm_r        <= ST_DONE;
              end else begin
                rx_frame_cnt_r <= sat_inc(rx_frame_cnt_r);
                last_err_r     <= 32'd0;
                fsm_r          <= ST_SEND_META;
              end
            end
          end
        end

        // -- Emit TX metadata, then start payload --
        ST_SEND_META: begin
          if (udp_tx_meta_ready_i) begin
            rd_ptr_r <= '0;
            // wr_ptr_r is now stable (updated last cycle); skip echo for 0-byte payload
            fsm_r <= (wr_ptr_r == '0) ? ST_DONE : ST_SEND_PAY;
          end
        end

        // -- Stream buffer bytes to TX --
        ST_SEND_PAY: begin
          if (udp_tx_ready_i) begin
            if (tx_byte_cnt_r != 32'hFFFF_FFFF) tx_byte_cnt_r <= tx_byte_cnt_r + 32'd1;
            if (rd_ptr_r == wr_ptr_r - 1'b1) begin
              tx_frame_cnt_r <= sat_inc(tx_frame_cnt_r);
              fsm_r          <= ST_DONE;
            end else begin
              rd_ptr_r <= rd_ptr_r + 1'b1;
            end
          end
        end

        // -- Update drop counter, return to IDLE --
        ST_DONE: begin
          if (drop_r) rx_drop_cnt_r <= sat_inc(rx_drop_cnt_r);
          fsm_r <= ST_IDLE;
        end

        default: fsm_r <= ST_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Combinational output assignments
  // ---------------------------------------------------------------------------
  assign udp_rx_meta_ready_o = (fsm_r == ST_IDLE);
  assign udp_rx_ready_o      = (fsm_r == ST_DROP || fsm_r == ST_RECV);

  assign udp_tx_meta_valid_o = (fsm_r == ST_SEND_META);
  assign udp_tx_dst_ip_o     = echo_dst_ip_r;
  assign udp_tx_dst_port_o   = echo_dst_port_r;
  assign udp_tx_src_port_o   = udp_port_w;
  assign udp_tx_length_o     = {{(16-ABITS){1'b0}}, wr_ptr_r};

  assign udp_tx_valid_o = (fsm_r == ST_SEND_PAY);
  assign udp_tx_data_o  = payload_mem_r[rd_ptr_r];
  assign udp_tx_last_o  = (rd_ptr_r == wr_ptr_r - 1'b1);

  assign irq_o = 1'b0;

  // ---------------------------------------------------------------------------
  // Register file hw_rdata connections
  // ---------------------------------------------------------------------------
  wire rx_active_w = (fsm_r == ST_RECV);
  wire tx_active_w = (fsm_r == ST_SEND_META || fsm_r == ST_SEND_PAY);

  assign hw_rdata_w[0*32 +: 32]  = 32'h4554_485F;          // ID "ETH_"
  assign hw_rdata_w[1*32 +: 32]  = 32'h0001_0000;          // VERSION
  assign hw_rdata_w[2*32 +: 32]  = 32'h0;                  // CONTROL (RW, unused slot)
  assign hw_rdata_w[3*32 +: 32]  = {                        // STATUS
    24'd0,
    (fsm_r != ST_IDLE) ? 1'b1 : 1'b0,  // bit6: busy
    (link_up_i & en_w),                  // bit5: udp_ready
    1'b0,                                // bit4: arp_ready (not implemented)
    tx_active_w,                         // bit3: tx_active
    rx_active_w,                         // bit2: rx_active
    en_w,                                // bit1: enabled
    link_up_i                            // bit0: link_up
  };
  assign hw_rdata_w[4*32 +: 32]  = 32'h0;           // LOCAL_IP (RW, unused slot)
  assign hw_rdata_w[5*32 +: 32]  = 32'h0;           // UDP_PORT (RW, unused slot)
  assign hw_rdata_w[6*32 +: 32]  = rx_frame_cnt_r;
  assign hw_rdata_w[7*32 +: 32]  = tx_frame_cnt_r;
  assign hw_rdata_w[8*32 +: 32]  = rx_byte_cnt_r;
  assign hw_rdata_w[9*32 +: 32]  = tx_byte_cnt_r;
  assign hw_rdata_w[10*32 +: 32] = rx_drop_cnt_r;
  assign hw_rdata_w[11*32 +: 32] = rx_err_cnt_r;
  assign hw_rdata_w[12*32 +: 32] = tx_err_cnt_r;
  assign hw_rdata_w[13*32 +: 32] = last_src_ip_r;
  assign hw_rdata_w[14*32 +: 32] = last_src_port_r;
  assign hw_rdata_w[15*32 +: 32] = last_dst_port_r;
  assign hw_rdata_w[16*32 +: 32] = last_plen_r;
  assign hw_rdata_w[17*32 +: 32] = last_err_r;
  assign hw_rdata_w[18*32 +: 32] = 32'h0;           // CLEAR_COUNTERS (PULSE, write-only)

endmodule

`endif // ETH_UDP_ECHO_TEST_SV
