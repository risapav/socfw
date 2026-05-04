`default_nettype none

import hdmi_pkg::*;

// 2-stage pipelined TMDS video encoder (per DVI 1.0 / HDMI spec).
// Stage 1 (combinational → register): compute q_m and ones count.
// Stage 2 (register → output): DC-balance decision and running disparity update.
//
// de_i gates the running-disparity accumulator: when de_i is low (blanking or
// control period) the disparity register is held at zero so that active-video
// always begins with a fresh, balanced state.
//
// localparam LATENCY = 2 (clock cycles from data_i/de_i to tmds_o).
module tmds_video_encoder (
  input  logic       clk_i,
  input  logic       rst_ni,

  input  logic       de_i,    // display-enable: gates running disparity
  input  tmds_data_t data_i,  // 8-bit video channel byte

  output tmds_word_t tmds_o   // 10-bit TMDS word
);

  localparam int LATENCY = 2;

  // ── Stage 1: transition-minimised word (q_m) ─────────────────────────────
  function automatic logic [3:0] count_ones8(input logic [7:0] d);
    logic [3:0] n = '0;
    for (int i = 0; i < 8; i++) n += d[i];
    return n;
  endfunction

  function automatic logic [4:0] count_ones10(input logic [9:0] d);
    logic [4:0] n = '0;
    for (int i = 0; i < 10; i++) n += d[i];
    return n;
  endfunction

  logic [8:0]   q_m_s1;
  logic [3:0]   ones_s1;

  always_comb begin
    logic [7:0] q_m;
    logic       use_xor;
    logic [3:0] cnt;

    cnt     = count_ones8(data_i);
    // Use XOR (use_xor=1) when transition count is lower with XOR than XNOR.
    // DVI spec: use XNOR when ones > 4 or (ones == 4 and data[0] == 0).
    use_xor = !((cnt > 4) || (cnt == 4 && data_i[0] == 1'b0));

    q_m[0] = data_i[0];
    for (int i = 1; i < 8; i++)
      q_m[i] = use_xor ? (q_m[i-1] ^ data_i[i]) : ~(q_m[i-1] ^ data_i[i]);

    // q_m[8]: 1 = XOR path used, 0 = XNOR path used
    q_m_s1 = {use_xor, q_m};
    ones_s1 = count_ones8(q_m);
  end

  // Pipeline register S1→S2 (also delays de_i to align with stage-2 data)
  logic [8:0]  q_m_r;
  logic [3:0]  ones_r;
  logic        de_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      q_m_r  <= '0;
      ones_r <= '0;
      de_r   <= 1'b0;
    end else begin
      q_m_r  <= q_m_s1;
      ones_r <= ones_s1;
      de_r   <= de_i;
    end
  end

  // ── Stage 2: DC-balance ───────────────────────────────────────────────────
  logic signed [4:0] rd;   // running disparity

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tmds_o <= '0;
      rd     <= 5'sd0;
    end else if (!de_r) begin
      // Blanking period: reset disparity so active video starts balanced
      rd     <= 5'sd0;
      tmds_o <= '0;
    end else begin
      logic signed [4:0] char_disp;
      logic              neutral;
      logic              invert;
      logic [9:0]        word;
      logic [4:0]        ones_out;
      logic signed [4:0] rd_next;

      // Disparity of the q_m word: ones - zeros = 2*ones - 8
      char_disp = $signed({1'b0, ones_r}) * 2 - 5'sd8;
      neutral   = (char_disp == 5'sd0);

      if (neutral)
        invert = q_m_r[8];          // prefer fewer transitions
      else if (rd == 5'sd0)
        invert = (char_disp > 5'sd0);
      else
        invert = (rd > 5'sd0) ? (char_disp > 5'sd0) : (char_disp < 5'sd0);

      if (invert)
        word = {1'b1, q_m_r[8], ~q_m_r[7:0]};
      else
        word = {1'b0, q_m_r[8],  q_m_r[7:0]};

      ones_out = count_ones10(word);
      rd_next  = rd + ($signed({1'b0, ones_out}) * 2 - 5'sd10);

      tmds_o <= word;
      rd     <= rd_next;
    end
  end

endmodule
