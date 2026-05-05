`ifndef HDMI_PKG_SV
`define HDMI_PKG_SV

`default_nettype none

package hdmi_pkg;

  typedef logic [9:0] tmds_word_t;
  typedef logic [7:0] tmds_data_t;

  // Eight-state HDMI period type (covers DVI + full HDMI data islands)
  typedef enum logic [2:0] {
    HDMI_PERIOD_CONTROL,         // blanking: HS/VS control symbols
    HDMI_PERIOD_VIDEO,           // active video: TMDS video encoding
    HDMI_PERIOD_VIDEO_PREAMBLE,  // 8-symbol preamble before video guard band
    HDMI_PERIOD_VIDEO_GB,        // video guard band (2 pixels before active)
    HDMI_PERIOD_DATA_PREAMBLE,   // 8-symbol preamble before data island
    HDMI_PERIOD_DATA_GB_LEAD,    // 2-symbol leading guard band
    HDMI_PERIOD_DATA_PAYLOAD,    // 32-symbol packet payload (TERC4)
    HDMI_PERIOD_DATA_GB_TRAIL    // 2-symbol trailing guard band
  } hdmi_period_t;

  typedef struct packed {
    logic [23:0] rgb;
    logic        de;
    logic        hsync;
    logic        vsync;
    logic        valid;
  } hdmi_video_sample_t;

  typedef struct packed {
    logic [15:0] h_active;
    logic [15:0] h_front_porch;
    logic [15:0] h_sync;
    logic [15:0] h_back_porch;
    logic [15:0] v_active;
    logic [15:0] v_front_porch;
    logic [15:0] v_sync;
    logic [15:0] v_back_porch;
    logic        hsync_polarity;
    logic        vsync_polarity;
  } hdmi_video_cfg_t;

  typedef struct packed {
    logic [2:0] sample_rate;
    logic [1:0] channels;
    logic [4:0] sample_width;
    logic       enable;
  } hdmi_audio_cfg_t;

  typedef struct packed {
    logic send_avi;
    logic send_audio;
    logic send_spd;
    logic rgb_quant_full;
  } hdmi_info_cfg_t;

  // InfoFrame types (CEA-861)
  typedef enum logic [7:0] {
    INFO_AVI    = 8'h82,
    INFO_SPD    = 8'h83,
    INFO_AUDIO  = 8'h84,
    INFO_VENDOR = 8'h81
  } infoframe_type_e;

  typedef enum logic [1:0] {
    ASPECT_RATIO_NONE = 2'b00,
    ASPECT_RATIO_4_3  = 2'b01,
    ASPECT_RATIO_16_9 = 2'b10
  } aspect_ratio_e;

  typedef enum logic [1:0] {
    COLOR_FORMAT_RGB    = 2'b00,
    COLOR_FORMAT_YUV422 = 2'b01,
    COLOR_FORMAT_YUV444 = 2'b10
  } color_format_e;

  typedef enum logic [1:0] {
    QUANT_RANGE_DEFAULT = 2'b00,
    QUANT_RANGE_LIMITED = 2'b01,
    QUANT_RANGE_FULL    = 2'b10
  } quant_range_e;

  // Checksum helper: header[3] + payload[1..payload_len-1], payload[0] is the slot
  // for the result. payload_len = number_of_PB_bytes + 1.
  function automatic logic [7:0] calc_checksum(
    input logic [7:0] header[3],
    input logic [7:0] payload[32],
    input int         payload_len
  );
    logic [15:0] sum;
    sum = 0;
    for (int i = 0; i < 3; i++)
      sum += header[i];
    for (int i = 1; i < payload_len; i++)
      sum += payload[i];
    return -sum[7:0];
  endfunction

endpackage : hdmi_pkg

`endif
