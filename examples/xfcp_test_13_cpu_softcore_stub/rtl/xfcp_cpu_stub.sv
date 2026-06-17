/**
 * @file  xfcp_cpu_stub.sv
 * @brief CPU-side mailbox agent stub: PING->PONG, unknown->ERR.
 *
 * @details
 *   Demo/test CPU-side FSM pre axil_cpu_mailbox native CPU porty.
 *   Caka na prichod paketu cez RX FIFO, dekoduje command a posle odpoved cez TX FIFO.
 *
 *   Podporovane prikazy (max MAX_CMD_BYTES bajtov + tlast):
 *     "PING" (50 49 4E 47, tlast na 4. bajte) -> odpoved "PONG" (50 4F 4E 47)
 *     cokolok ine                             -> odpoved "ERR\n" (45 52 52 0A)
 *
 *   Handshake (z axil_cpu_mailbox):
 *     cpu_rx_pop_o  assertovat iba ked cpu_rx_valid_i=1
 *     cpu_tx_push_o assertovat iba ked cpu_tx_ready_i=1
 *
 * @param MAX_CMD_BYTES  Max dlzka prijateho prikazu v bajtoch (default 8)
 */

`ifndef XFCP_CPU_STUB_SV
`define XFCP_CPU_STUB_SV

`default_nettype none

module xfcp_cpu_stub #(
  parameter int MAX_CMD_BYTES = 8
)(
  input  wire        clk_i,
  input  wire        rst_ni,

  // Native CPU RX port (z axil_cpu_mailbox.cpu_rx_*)
  input  wire [8:0]  cpu_rx_data_i,    // {tlast, data[7:0]}
  input  wire        cpu_rx_valid_i,
  output logic       cpu_rx_pop_o,

  // Native CPU TX port (do axil_cpu_mailbox.cpu_tx_*)
  output logic [8:0] cpu_tx_data_o,    // {tlast, data[7:0]}
  output logic       cpu_tx_push_o,
  input  wire        cpu_tx_ready_i
);

  // ── Response ROM ──────────────────────────────────────────────────────────
  localparam int RESP_LEN = 4;

  localparam logic [7:0] RESP_PONG [RESP_LEN] = '{8'h50, 8'h4F, 8'h4E, 8'h47}; // "PONG"
  localparam logic [7:0] RESP_ERR  [RESP_LEN] = '{8'h45, 8'h52, 8'h52, 8'h0A}; // "ERR\n"

  // ── FSM ───────────────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    ST_IDLE = 2'b00,
    ST_RX   = 2'b01,
    ST_PROC = 2'b10,
    ST_TX   = 2'b11
  } state_e;

  state_e         state_q;
  logic [7:0]     cmd_buf_q [MAX_CMD_BYTES];
  logic [3:0]     cmd_len_q;     // pocet prijatych bajtov (max 15)
  logic [2:0]     tx_idx_q;      // index aktualneho TX bajtu (0..RESP_LEN-1)
  logic           is_ping_q;     // dekodovany prikaz: 1=PING, 0=ERR

  // ── TX mux: vyber odpovede podla is_ping_q ───────────────────────────────
  logic [7:0] tx_byte_w;
  always_comb begin
    if (is_ping_q)
      tx_byte_w = RESP_PONG[tx_idx_q[1:0]];
    else
      tx_byte_w = RESP_ERR[tx_idx_q[1:0]];
  end

  logic tx_last_w;
  assign tx_last_w = (tx_idx_q == (RESP_LEN - 1));

  // ── Output drives ─────────────────────────────────────────────────────────
  assign cpu_rx_pop_o  = (state_q == ST_RX)  && cpu_rx_valid_i;
  assign cpu_tx_push_o = (state_q == ST_TX)  && cpu_tx_ready_i;
  assign cpu_tx_data_o = {tx_last_w, tx_byte_w};

  // ── FSM sequential ───────────────────────────────────────────────────────
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= ST_IDLE;
      cmd_len_q <= '0;
      tx_idx_q  <= '0;
      is_ping_q <= 1'b0;
      for (int i = 0; i < MAX_CMD_BYTES; i++) cmd_buf_q[i] <= '0;
    end else begin
      case (state_q)

        ST_IDLE: begin
          if (cpu_rx_valid_i) begin
            cmd_len_q <= '0;
            for (int i = 0; i < MAX_CMD_BYTES; i++) cmd_buf_q[i] <= '0;
            state_q   <= ST_RX;
          end
        end

        ST_RX: begin
          if (cpu_rx_valid_i) begin
            // pop fires this cycle (cpu_rx_pop_o=1)
            if (cmd_len_q < MAX_CMD_BYTES) begin
              cmd_buf_q[cmd_len_q[2:0]] <= cpu_rx_data_i[7:0];
            end
            if (cmd_len_q < 4'hF) cmd_len_q <= cmd_len_q + 4'd1;

            if (cpu_rx_data_i[8]) begin  // tlast
              state_q <= ST_PROC;
            end
          end
        end

        ST_PROC: begin
          // 1-cycle decode: PING = 50 49 4E 47, len>=4 with tlast on 4th byte
          is_ping_q <= (cmd_len_q == 4'd4) &&
                       (cmd_buf_q[0] == 8'h50) &&  // 'P'
                       (cmd_buf_q[1] == 8'h49) &&  // 'I'
                       (cmd_buf_q[2] == 8'h4E) &&  // 'N'
                       (cmd_buf_q[3] == 8'h47);    // 'G'
          tx_idx_q  <= '0;
          state_q   <= ST_TX;
        end

        ST_TX: begin
          if (cpu_tx_ready_i) begin
            // push fires this cycle (cpu_tx_push_o=1)
            if (tx_last_w) begin
              state_q <= ST_IDLE;
            end else begin
              tx_idx_q <= tx_idx_q + 3'd1;
            end
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

endmodule

`endif // XFCP_CPU_STUB_SV
