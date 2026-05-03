`ifndef HDMI_PACKAGE
`define HDMI_PACKAGE

`default_nettype none

package hdmi_pkg;

    // --------------------------------------------------------
    // Typy pre HDMI
    // --------------------------------------------------------

`ifndef RGB888_T_DEFINED
`define RGB888_T_DEFINED
    /** @brief Dátový typ pre jeden pixel vo formáte RGB888 (24 bitov). */
  typedef struct packed {
    logic [7:0] red; ///< @brief 8 bitov pre červenú zložku.
    logic [7:0] grn; ///< @brief 8 bitov pre zelenú zložku.
    logic [7:0] blu; ///< @brief 8 bitov pre modrú zložku.
  } rgb888_t;
`endif

    // Dátový typ pre 10-bitové TMDS dáta (jeden kanál)
    typedef logic [9:0] tmds_word_t;

    // 8-bit TMDS dátový symbol
    typedef logic [7:0] tmds_data_t;

    // Pole pre všetky 4 TMDS kanály (B, G, R, CLK)
    typedef tmds_word_t tmds_channel_data_t[0:3];

    // Typ periódy TMDS
    typedef enum logic [1:0] {
        VIDEO_PERIOD,   // 00: Aktívne video
        CONTROL_PERIOD, // 01: HSync/VSync
        AUDIO_PERIOD,   // 10: Audio guard band
        DATA_PERIOD     // 11: InfoFrame guard band
    } tmds_period_e;

    // Typy InfoFrame
    typedef enum logic [7:0] {
        INFO_AVI    = 8'h82,
        INFO_SPD    = 8'h83,
        INFO_AUDIO  = 8'h84,
        INFO_VENDOR = 8'h81
    } infoframe_type_e;

    // NOVÉ TYPY PRE INFOFRAME BUILDER
    typedef enum logic [1:0] {
        ASPECT_RATIO_NONE = 2'b00,
        ASPECT_RATIO_4_3  = 2'b01,
        ASPECT_RATIO_16_9 = 2'b10
    } aspect_ratio_e;

    typedef enum logic [1:0] {
        COLOR_FORMAT_RGB   = 2'b00,
        COLOR_FORMAT_YUV422 = 2'b01,
        COLOR_FORMAT_YUV444 = 2'b10
    } color_format_e;

    typedef enum logic [1:0] {
        QUANT_RANGE_DEFAULT  = 2'b00,
        QUANT_RANGE_LIMITED = 2'b01,
        QUANT_RANGE_FULL    = 2'b10
    } quant_range_e;


    // --------------------------------------------------------
    // Funkcia na výpočet checksumu
    // --------------------------------------------------------
    // Poznámka: Quartus nepodporuje open arrays ani parametrizované funkcie,
    // preto sú rozmery fixné: header[3], payload[32].
    // Skutočná dĺžka payloadu sa dá cez payload_len.
    // --------------------------------------------------------
    function automatic logic [7:0] calc_checksum(
        input logic [7:0] header[3],
        input logic [7:0] payload[32],
        input int payload_len
    );
        logic [15:0] sum;
        int i;

        sum = 0;

        // Header (3 bajty)
        for (i = 0; i < 3; i++)
            sum += header[i];

        // Payload (od indexu 1, lebo [0] je checksum)
        for (i = 1; i < payload_len; i++)
            sum += payload[i];

        return -sum[7:0]; // dvojkový doplnok
    endfunction

endpackage : hdmi_pkg

`endif
