/**
 * @file taxi_lfsr.sv
 * @brief Parametrizable combinatorial parallel LFSR/CRC (Alex Forencich).
 * @param LFSR_W       Width of LFSR/CRC register.
 * @param LFSR_POLY    LFSR/CRC polynomial (e.g. 32'h04c11db7 for CRC32).
 * @param LFSR_GALOIS  0=Fibonacci, 1=Galois.
 * @param REVERSE      Bit-reverse input and output (set for Ethernet LSB-first).
 * @param DATA_W       Width of data ports.
 * @param DATA_IN_EN   Enable data input port.
 * @param DATA_OUT_EN  Enable data output port.
 * @details CRC32 Ethernet config: LFSR_W=32, LFSR_POLY=32'h04c11db7, LFSR_GALOIS=1,
 *   REVERSE=1, DATA_W=8, DATA_IN_EN=1, DATA_OUT_EN=0. init=32'hFFFFFFFF, final=~state.
 */
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2016-2026 FPGA Ninja, LLC
// Authors: Alex Forencich
`ifndef TAXI_LFSR_SV
`define TAXI_LFSR_SV

`resetall
`default_nettype none

module taxi_lfsr #(
  parameter int unsigned LFSR_W = 31,
  parameter logic [LFSR_W-1:0] LFSR_POLY = 31'h10000001,
  parameter logic LFSR_GALOIS = 1'b0,
  parameter logic LFSR_FEED_FORWARD = 1'b0,
  parameter logic REVERSE = 1'b0,
  parameter int unsigned DATA_W = 8,
  parameter logic DATA_IN_EN = 1'b1,
  parameter logic DATA_OUT_EN = 1'b1,
  parameter int STATE_SHIFT_PRE = 0,
  parameter int STATE_SHIFT_POST = 0
) (
  input  logic [DATA_W-1:0]  data_in,
  input  logic [LFSR_W-1:0]  state_in,
  output logic [DATA_W-1:0]  data_out,
  output logic [LFSR_W-1:0]  state_out
);

localparam logic INPUT_DATA_IN_STATE =
  DATA_IN_EN && LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W <= LFSR_W;
localparam logic INPUT_STATE_IN_DATA =
  DATA_IN_EN && LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W > LFSR_W;
localparam logic OUTPUT_DATA_IN_STATE =
  DATA_OUT_EN && !LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W <= LFSR_W;
localparam logic OUTPUT_STATE_IN_DATA =
  DATA_OUT_EN && !LFSR_GALOIS && !LFSR_FEED_FORWARD && DATA_W > LFSR_W;

localparam logic DATA_IN_INT = DATA_IN_EN && !INPUT_DATA_IN_STATE;
localparam logic DATA_OUT_INT = DATA_OUT_EN && !OUTPUT_DATA_IN_STATE;

localparam int unsigned IN_W = INPUT_STATE_IN_DATA ? DATA_W : (LFSR_W+(DATA_IN_INT ? DATA_W : 0));
localparam int unsigned OUT_W = OUTPUT_STATE_IN_DATA ? DATA_W : (LFSR_W+(DATA_OUT_INT ? DATA_W : 0));

function automatic logic [OUT_W-1:0][IN_W-1:0] lfsr_mask();
  logic [LFSR_W-1:0] lfsr_mask_state[LFSR_W-1:0];
  logic [DATA_W-1:0] lfsr_mask_data[LFSR_W-1:0];
  logic [LFSR_W-1:0] output_mask_state[DATA_W-1:0];
  logic [DATA_W-1:0] output_mask_data[DATA_W-1:0];

  logic [LFSR_W-1:0] state_val;
  logic [DATA_W-1:0] data_val;
  logic [DATA_W-1:0] data_mask;

  lfsr_mask = '0;

  for (integer i = 0; i < LFSR_W; i = i + 1) begin
    lfsr_mask_state[i] = '0;
    lfsr_mask_state[i][i] = 1'b1;
    lfsr_mask_data[i] = '0;
  end
  for (integer i = 0; i < DATA_W; i = i + 1) begin
    output_mask_state[i] = '0;
    output_mask_data[i] = '0;
  end

  if (LFSR_GALOIS) begin
    if (STATE_SHIFT_PRE > 0) begin
      for (integer i = 0; i < STATE_SHIFT_PRE; i = i + 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
            lfsr_mask_data[j]  = lfsr_mask_data[j]  ^ data_val;
          end
        end
      end
    end else if (STATE_SHIFT_PRE < 0) begin
      for (integer i = 0; i < -STATE_SHIFT_PRE; i = i + 1) begin
        state_val = lfsr_mask_state[0];
        data_val  = lfsr_mask_data[0];
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
            lfsr_mask_data[j]  = lfsr_mask_data[j]  ^ data_val;
          end
        end
        for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j+1];
          lfsr_mask_data[j]  = lfsr_mask_data[j+1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[LFSR_W-1] = state_val;
        lfsr_mask_data[LFSR_W-1]  = data_val;
      end
    end

    if (DATA_IN_EN || DATA_OUT_EN) begin
      for (data_mask = {1'b1, {DATA_W-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        data_val  = data_val ^ data_mask;
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        for (integer j = DATA_W-1; j > 0; j = j - 1) begin
          output_mask_state[j] = output_mask_state[j-1];
          output_mask_data[j]  = output_mask_data[j-1];
        end
        output_mask_state[0] = state_val;
        output_mask_data[0]  = data_val;
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = data_mask;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
            lfsr_mask_data[j]  = lfsr_mask_data[j]  ^ data_val;
          end
        end
      end
    end

    if (STATE_SHIFT_POST > 0) begin
      for (integer i = 0; i < STATE_SHIFT_POST; i = i + 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
            lfsr_mask_data[j]  = lfsr_mask_data[j]  ^ data_val;
          end
        end
      end
    end else if (STATE_SHIFT_POST < 0) begin
      for (integer i = 0; i < -STATE_SHIFT_POST; i = i + 1) begin
        state_val = lfsr_mask_state[0];
        data_val  = lfsr_mask_data[0];
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            lfsr_mask_state[j] = lfsr_mask_state[j] ^ state_val;
            lfsr_mask_data[j]  = lfsr_mask_data[j]  ^ data_val;
          end
        end
        for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j+1];
          lfsr_mask_data[j]  = lfsr_mask_data[j+1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[LFSR_W-1] = state_val;
        lfsr_mask_data[LFSR_W-1]  = data_val;
      end
    end
  end else begin
    if (STATE_SHIFT_PRE > 0) begin
      for (integer i = 0; i < STATE_SHIFT_PRE; i = i + 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            state_val = lfsr_mask_state[j-1] ^ state_val;
            data_val  = lfsr_mask_data[j-1]  ^ data_val;
          end
        end
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
      end
    end else if (STATE_SHIFT_PRE < 0) begin
      for (integer i = 0; i < -STATE_SHIFT_PRE; i = i + 1) begin
        state_val = lfsr_mask_state[0];
        data_val  = lfsr_mask_data[0];
        for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j+1];
          lfsr_mask_data[j]  = lfsr_mask_data[j+1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[LFSR_W-1] = state_val;
        lfsr_mask_data[LFSR_W-1]  = data_val;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            state_val = lfsr_mask_state[j-1] ^ state_val;
            data_val  = lfsr_mask_data[j-1]  ^ data_val;
          end
        end
      end
    end

    if (DATA_IN_EN || DATA_OUT_EN) begin
      for (data_mask = {1'b1, {DATA_W-1{1'b0}}}; data_mask != 0; data_mask = data_mask >> 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        data_val  = data_val ^ data_mask;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            state_val = lfsr_mask_state[j-1] ^ state_val;
            data_val  = lfsr_mask_data[j-1]  ^ data_val;
          end
        end
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        for (integer j = DATA_W-1; j > 0; j = j - 1) begin
          output_mask_state[j] = output_mask_state[j-1];
          output_mask_data[j]  = output_mask_data[j-1];
        end
        output_mask_state[0] = state_val;
        output_mask_data[0]  = data_val;
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = data_mask;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
      end
    end

    if (STATE_SHIFT_POST > 0) begin
      for (integer i = 0; i < STATE_SHIFT_POST; i = i + 1) begin
        state_val = lfsr_mask_state[LFSR_W-1];
        data_val  = lfsr_mask_data[LFSR_W-1];
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            state_val = lfsr_mask_state[j-1] ^ state_val;
            data_val  = lfsr_mask_data[j-1]  ^ data_val;
          end
        end
        for (integer j = LFSR_W-1; j > 0; j = j - 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j-1];
          lfsr_mask_data[j]  = lfsr_mask_data[j-1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[0] = state_val;
        lfsr_mask_data[0]  = data_val;
      end
    end else if (STATE_SHIFT_POST < 0) begin
      for (integer i = 0; i < -STATE_SHIFT_POST; i = i + 1) begin
        state_val = lfsr_mask_state[0];
        data_val  = lfsr_mask_data[0];
        for (integer j = 0; j < LFSR_W-1; j = j + 1) begin
          lfsr_mask_state[j] = lfsr_mask_state[j+1];
          lfsr_mask_data[j]  = lfsr_mask_data[j+1];
        end
        if (LFSR_FEED_FORWARD) begin
          state_val = '0;
          data_val  = '0;
        end
        lfsr_mask_state[LFSR_W-1] = state_val;
        lfsr_mask_data[LFSR_W-1]  = data_val;
        for (integer j = 1; j < LFSR_W; j = j + 1) begin
          if (LFSR_POLY[j]) begin
            state_val = lfsr_mask_state[j-1] ^ state_val;
            data_val  = lfsr_mask_data[j-1]  ^ data_val;
          end
        end
      end
    end
  end

  /* verilator lint_off WIDTH */
  if (REVERSE) begin
    if (OUTPUT_STATE_IN_DATA) begin
      for (integer i = 0; i < DATA_W; i = i + 1) begin
        if (INPUT_STATE_IN_DATA) begin
          for (integer j = 0; j < DATA_W; j = j + 1)
            lfsr_mask[i][j] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
        end else begin
          for (integer j = 0; j < LFSR_W; j = j + 1)
            lfsr_mask[i][j] = output_mask_state[DATA_W-i-1][LFSR_W-j-1];
          if (DATA_IN_INT)
            for (integer j = 0; j < DATA_W; j = j + 1)
              lfsr_mask[i][j+LFSR_W] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
        end
      end
    end else begin
      for (integer i = 0; i < LFSR_W; i = i + 1) begin
        if (INPUT_STATE_IN_DATA) begin
          for (integer j = 0; j < DATA_W; j = j + 1)
            lfsr_mask[i][j] = lfsr_mask_data[LFSR_W-i-1][DATA_W-j-1];
        end else begin
          for (integer j = 0; j < LFSR_W; j = j + 1)
            lfsr_mask[i][j] = lfsr_mask_state[LFSR_W-i-1][LFSR_W-j-1];
          if (DATA_IN_INT)
            for (integer j = 0; j < DATA_W; j = j + 1)
              lfsr_mask[i][j+LFSR_W] = lfsr_mask_data[LFSR_W-i-1][DATA_W-j-1];
        end
      end
      if (DATA_OUT_INT) begin
        for (integer i = 0; i < DATA_W; i = i + 1) begin
          if (INPUT_STATE_IN_DATA) begin
            for (integer j = 0; j < DATA_W; j = j + 1)
              lfsr_mask[i+LFSR_W][j] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
          end else begin
            for (integer j = 0; j < LFSR_W; j = j + 1)
              lfsr_mask[i+LFSR_W][j] = output_mask_state[DATA_W-i-1][LFSR_W-j-1];
            if (DATA_IN_INT)
              for (integer j = 0; j < DATA_W; j = j + 1)
                lfsr_mask[i+LFSR_W][j+LFSR_W] = output_mask_data[DATA_W-i-1][DATA_W-j-1];
          end
        end
      end
    end
  end else begin
    if (OUTPUT_STATE_IN_DATA) begin
      for (integer i = 0; i < DATA_W; i = i + 1) begin
        if (INPUT_STATE_IN_DATA)
          lfsr_mask[i] = output_mask_data[i];
        else if (DATA_IN_INT)
          lfsr_mask[i] = {output_mask_data[i], output_mask_state[i]};
        else
          lfsr_mask[i] = output_mask_state[i];
      end
    end else begin
      for (integer i = 0; i < LFSR_W; i = i + 1) begin
        if (INPUT_STATE_IN_DATA)
          lfsr_mask[i] = lfsr_mask_data[i];
        else if (DATA_IN_INT)
          lfsr_mask[i] = {lfsr_mask_data[i], lfsr_mask_state[i]};
        else
          lfsr_mask[i] = lfsr_mask_state[i];
      end
      if (DATA_OUT_INT) begin
        for (integer i = 0; i < DATA_W; i = i + 1) begin
          if (INPUT_STATE_IN_DATA)
            lfsr_mask[i+LFSR_W] = output_mask_data[i];
          else if (DATA_IN_INT)
            lfsr_mask[i+LFSR_W] = {output_mask_data[i], output_mask_state[i]};
          else
            lfsr_mask[i+LFSR_W] = output_mask_state[i];
        end
      end
    end
  end
  /* verilator lint_on WIDTH */
endfunction

localparam logic [OUT_W-1:0][IN_W-1:0] LFSR_MASK = lfsr_mask();

logic [IN_W-1:0]  lfsr_in;
logic [OUT_W-1:0] lfsr_out;

genvar g_xor_idx;

generate
  if (DATA_IN_EN) begin : g_data_in_en
    if (INPUT_STATE_IN_DATA) begin : g_input_state_in_data
      if (DATA_W == LFSR_W) begin : g_equal_width
        assign lfsr_in = data_in ^ state_in;
      end else begin : g_data_w_gt_lfsr_w
        if (REVERSE) begin : g_reverse
          assign lfsr_in = data_in ^ {{DATA_W - LFSR_W{1'b0}}, state_in};
        end else begin : g_no_reverse
          assign lfsr_in = data_in ^ {state_in, {DATA_W - LFSR_W{1'b0}}};
        end
      end
    end else if (INPUT_DATA_IN_STATE) begin : g_input_data_in_state
      if (REVERSE) begin : g_reverse
        assign lfsr_in = {{LFSR_W - DATA_W{1'b0}}, data_in} ^ state_in;
      end else begin : g_no_reverse
        assign lfsr_in = {data_in, {LFSR_W - DATA_W{1'b0}}} ^ state_in;
      end
    end else begin : g_input_concat
      assign lfsr_in = {data_in, state_in};
    end
  end else begin : g_data_in_dis
    assign lfsr_in = state_in;
  end

  for (g_xor_idx = 0; g_xor_idx < OUT_W; g_xor_idx = g_xor_idx + 1) begin : g_xor
    assign lfsr_out[g_xor_idx] = ^(lfsr_in & LFSR_MASK[g_xor_idx]);
  end

  if (OUTPUT_DATA_IN_STATE) begin : g_output_data_in_state
    assign state_out = lfsr_out;
    assign data_out = REVERSE ? lfsr_out[OUT_W-1 -: DATA_W] : lfsr_out[0 +: DATA_W];
  end else if (OUTPUT_STATE_IN_DATA) begin : g_output_state_in_data
    assign state_out = REVERSE ? lfsr_out[OUT_W-1 -: LFSR_W] : lfsr_out[0 +: LFSR_W];
    assign data_out = lfsr_out;
  end else begin : g_output_normal
    assign state_out = lfsr_out[0 +: LFSR_W];

    if (DATA_OUT_EN) begin : g_data_out_en
      assign data_out = lfsr_out[LFSR_W +: DATA_W];
    end else begin : g_data_out_dis
      assign data_out = '0;
    end
  end
endgenerate

endmodule

`resetall

`endif  // TAXI_LFSR_SV
