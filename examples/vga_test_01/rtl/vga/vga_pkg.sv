/**
 * @brief       VGA parametre a typy (balíček)
 * @details     Balíček `vga_pkg` definuje všetky potrebné konštanty, dátové typy, štruktúry a pomocné funkcie
 *              súvisiace s VGA časovaním a výstupom obrazu. Obsahuje štandardné režimy, polárne konštanty,
 *              preddefinované RGB farby, ako aj funkcie na výpočet VGA parametrov.
 *
 * @param[in]   MaxLineCounter     Maximálna hodnota pre generátor riadkov (`vga_line`). Definuje šírku čítača.
 * @param[in]   MaxPosCounterX     Maximálna horizontálna pozícia v pixeloch (napr. 1920).
 * @param[in]   MaxPosCounterY     Maximálna vertikálna pozícia v pixeloch (napr. 1080).
 * @param[in]   PulseActiveHigh    Konštanta definujúca aktívnu vysokú polaritu synchronizačných signálov.
 * @param[in]   PulseActiveLow     Konštanta definujúca aktívnu nízku polaritu synchronizačných signálov.
 *
 * @typedef     vga_mode_e         Výčtový typ definujúci podporované VGA režimy podľa VESA.
 * @typedef     line_t             Štruktúra popisujúca časovanie (visible_area, sync_pulse atď.) a polaritu.
 * @typedef     vga_data_t         Formát pixelu RGB565 (5:6:5).
 * @typedef     rgb565_t           Formát pixelu RGB565 (5:6:5).
 * @typedef     rgb888_t           Formát pixelu RGB888 (8:8:8).
 * @typedef     vga_sync_t         Štruktúra synchronizačných signálov (hs, vs).
 * @typedef     vga_params_t       Zjednotená štruktúra s horizontálnym a vertikálnym časovaním.
 *
 * @function    get_vga_params()   Vráti kompletné časovanie (H + V) pre daný VGA režim.
 * @function    get_pixel_clock()  Vráti požadovanú frekvenciu pixelov v Hz pre daný VGA režim.
 * @function    get_total_pixels_per_frame()  Vypočíta celkový počet pixelov v jednej snímke (s blankingom).
 *
 * @output      RGB farby          Konštanty `RED`, `GREEN`, `BLUE`, `WHITE` atď. vo formáte `vga_data_t`.
 *
 * @example
 * Použitie v module:
 *   import vga_pkg::*;
 *
 *   vga_params_t params = get_vga_params(VGA_800x600_60);
 *   int clk_hz = get_pixel_clock(VGA_800x600_60);
 */



`ifndef VGA_PKG_DONE
`define VGA_PKG_DONE

`timescale 1ns / 1ns

package vga_pkg;

  // =========================================================================
  // @section Globálne parametre pre šírku hardvéru
  // Tieto parametre definujú maximálnu možnú hodnotu pre počítadlá,
  // čím určujú veľkosť hardvérových registrov.
  // =========================================================================
  parameter int MaxLineCounter = 1920; ///< @brief Maximálna dĺžka periódy pre generátor `vga_line`.
  parameter int MaxPosCounterX = 1920; ///< @brief Maximálna hodnota pre X-ovú súradnicu.
  parameter int MaxPosCounterY = 1080; ///< @brief Maximálna hodnota pre Y-ovú súradnicu.

  /// @brief Šírka počítadla pre `vga_line`, odvodená z `MaxLineCounter`.
  localparam int LineCounterWidth = $clog2(MaxLineCounter);
  /// @brief Šírka registra pre X-ovú súradnicu.
  localparam int PosCounterWidthX = $clog2(MaxPosCounterX);
  /// @brief Šírka registra pre Y-ovú súradnicu.
  localparam int PosCounterWidthY = $clog2(MaxPosCounterY);


  // =========================================================================
  // @section Konštanty pre polaritu signálov
  // Definuje, či je synchronizačný pulz aktívny pri vysokej alebo nízkej úrovni.
  // =========================================================================
  localparam bit PulseActiveHigh = 1'b1; ///< @brief Polarita aktívna vo vysokej úrovni (Positive Polarity).
  localparam bit PulseActiveLow  = 1'b0; ///< @brief Polarita aktívna v nízkej úrovni (Negative Polarity).

  // =========================================================================
  // @section Podporované VGA režimy
  // Zoznam štandardných VGA režimov definovaných podľa VESA štandardov.
  // =========================================================================
  typedef enum logic [3:0] {
    VGA_640x480_60,   ///< @brief Režim 640x480 @ 60Hz
    VGA_800x600_60,   ///< @brief Režim 800x600 @ 60Hz
    VGA_1024x768_60,  ///< @brief Režim 1024x768 @ 60Hz
    VGA_1024x768_70,  ///< @brief Režim 1024x768 @ 70Hz
    VGA_1280x720_60,  ///< @brief Režim 1280x720 @ 60Hz (HD)
    VGA_1280x1024_60, ///< @brief Režim 1280x1024 @ 60Hz
    VGA_1680x1050_60, ///< @brief Režim 1680x1050 @ 60Hz
    VGA_1920x1080_60, ///< @brief Režim 1920x1080 @ 60Hz (Full HD)
    VGA_1920x1080_75, ///< @brief Režim 1920x1080 @ 75Hz
    VGA_1920x1080_85  ///< @brief Režim 1920x1080 @ 85Hz
  } vga_mode_e;

  // =========================================================================
  // @section Dátové typy a štruktúry
  // =========================================================================

  /** @brief Štruktúra definujúca časovanie pre jednu periódu (horizontálnu alebo vertikálnu). */
  typedef struct packed {
    logic [LineCounterWidth-1:0] visible_area; ///< @brief Počet cyklov aktívnej (viditeľnej) oblasti.
    logic [LineCounterWidth-1:0] front_porch;  ///< @brief Počet cyklov prednej verandy.
    logic [LineCounterWidth-1:0] sync_pulse;   ///< @brief Počet cyklov synchronizačného pulzu.
    logic [LineCounterWidth-1:0] back_porch;   ///< @brief Počet cyklov zadnej verandy.
    bit                          polarity;     ///< @brief Polarita synchronizačného pulzu (používa `PulseActiveHigh`/`PulseActiveLow`).
  } line_t;

  /** @brief Dátový typ pre jeden pixel vo formáte RGB565 (16 bitov). */
  typedef struct packed {
    logic [4:0] red; ///< @brief 5 bitov pre červenú zložku.
    logic [5:0] grn; ///< @brief 6 bitov pre zelenú zložku.
    logic [4:0] blu; ///< @brief 5 bitov pre modrú zložku.
  } vga_data_t;

  /** @brief Dátový typ pre jeden pixel vo formáte RGB565 (16 bitov). */
  typedef struct packed {
    logic [4:0] red; ///< @brief 5 bitov pre červenú zložku.
    logic [5:0] grn; ///< @brief 6 bitov pre zelenú zložku.
    logic [4:0] blu; ///< @brief 5 bitov pre modrú zložku.
  } rgb565_t;

`ifndef RGB888_T_DEFINED
`define RGB888_T_DEFINED
    /** @brief Dátový typ pre jeden pixel vo formáte RGB888 (24 bitov). */
  typedef struct packed {
    logic [7:0] red; ///< @brief 8 bitov pre červenú zložku.
    logic [7:0] grn; ///< @brief 8 bitov pre zelenú zložku.
    logic [7:0] blu; ///< @brief 8 bitov pre modrú zložku.
  } rgb888_t;
`endif

  /** @brief Štruktúra pre synchronizačné signály. */
  typedef struct packed {
    logic hs; ///< @brief Horizontálny synchronizačný signál.
    logic vs; ///< @brief Vertikálny synchronizačný signál.
  } vga_sync_t;

  /** @brief Zjednotená štruktúra obsahujúca kompletné parametre pre H aj V časovanie. */
  typedef struct packed {
    line_t h_line; ///< @brief Horizontálne časovacie parametre.
    line_t v_line; ///< @brief Vertikálne časovacie parametre.
  } vga_params_t;

  // =========================================================================
  // @section Preddefinované RGB565 farby
  // Konštanty pre základné farby vo formáte `vga_data_t`.
  // =========================================================================
  localparam vga_data_t
    RED      = 16'hF800, GREEN    = 16'h07E0, BLUE     = 16'h001F,
    YELLOW   = 16'hFFE0, CYAN     = 16'h07FF, PURPLE   = 16'hF81F,
    ORANGE   = 16'hFC00, BLACK    = 16'h0000, WHITE    = 16'hFFFF,
    DARKGRAY = 16'h8410;

`ifndef __ICARUS__
  // =========================================================================
  // @section Pomocné funkcie
  // Tieto funkcie slúžia na získanie konkrétnych hodnôt pre zvolený VGA režim.
  // Sú určené pre použitie pri elaborácii (nastavenie parametrov) alebo v testbenchoch.
  // =========================================================================

  /**
   * @brief Vráti štruktúru s časovacími parametrami pre daný VGA režim.
   * @param mode Vybraný VGA režim z `vga_mode_e`.
   * @return Kompletná štruktúra `vga_params_t` s hodnotami pre H a V časovanie.
   */
function automatic vga_params_t get_vga_params(input vga_mode_e mode);
    vga_params_t p;
    line_t h, v;

    // default
    h = '{default:0};
    v = '{default:0};

    case(mode)
        VGA_640x480_60: begin
            h = '{640,16,96,48,PulseActiveLow};
            v = '{480,10,2,33,PulseActiveLow};
        end
        VGA_800x600_60: begin
            h = '{800,40,128,88,PulseActiveHigh};
            v = '{600,1,4,23,PulseActiveHigh};
        end

        VGA_1024x768_60: begin
            h = '{1024,24, 136,160,PulseActiveLow};
            v = '{768,3,6,29,PulseActiveLow};
        end
        VGA_1024x768_70: begin
            h = '{1024,24,136,160,PulseActiveLow};
            v = '{768,3,6,29,PulseActiveLow};
        end
        VGA_1280x720_60: begin
            h = '{1280,110,40,220,PulseActiveHigh};
            v = '{720,5,5,20,PulseActiveHigh};
        end
        VGA_1280x1024_60: begin
            h = '{1280,48,112,248,PulseActiveHigh};
            v = '{1024,1,3,38,PulseActiveHigh};
        end
        VGA_1680x1050_60: begin
            h = '{1680,48,32,80, PulseActiveHigh};
            v = '{1050,3,6,21,PulseActiveLow};
        end
        VGA_1920x1080_60: begin
            h = '{1920,88,44,148,PulseActiveHigh};
            v = '{1080,4,5,36,PulseActiveHigh};
        end
        VGA_1920x1080_75: begin
            h = '{1920,80,80,200,PulseActiveHigh};
            v = '{1080,3,5,40,PulseActiveHigh};
        end
        VGA_1920x1080_85: begin
            h = '{1920,96,88,216,PulseActiveHigh};
            v = '{1080,3,6,42, PulseActiveHigh};
        end
        default: begin
            h = '{default:0};
            v = '{default:0};
        end
    endcase

    p.h_line = h;
    p.v_line = v;
    return p;
endfunction


  /**
   * @brief Vráti požadovanú pixelovú frekvenciu (v Hz) pre daný VGA režim.
   * @param mode Vybraný VGA režim z `vga_mode_e`.
   * @return Celočíselná hodnota frekvencie v Hertzoch.
   */
  function automatic int get_pixel_clock(input vga_mode_e mode);
    case (mode)
      VGA_640x480_60:     return 25_175_000;
      VGA_800x600_60:     return 40_000_000;
      VGA_1024x768_60:    return 65_000_000;
      VGA_1024x768_70:    return 75_000_000;
      VGA_1280x720_60:    return 74_250_000;
      VGA_1280x1024_60:   return 108_000_000;
      VGA_1680x1050_60:   return 119_000_000;
      VGA_1920x1080_60:   return 148_500_000;
      VGA_1920x1080_75:   return 183_600_000;
      VGA_1920x1080_85:   return 214_750_000;
      default:            return 0;
    endcase
  endfunction

  /**
   * @brief Vypočíta a vráti celkový počet pixelov v jednej snímke (vrátane blankingov).
   * @param mode Vybraný VGA režim z `vga_mode_e`.
   * @return Celkový počet pixelov (H_TOTAL * V_TOTAL).
   */
  function automatic int get_total_pixels_per_frame(input vga_mode_e mode);
    vga_params_t p = get_vga_params(mode);
    int h_total = p.h_line.visible_area + p.h_line.front_porch + p.h_line.sync_pulse + p.h_line.back_porch;
    int v_total = p.v_line.visible_area + p.v_line.front_porch + p.v_line.sync_pulse + p.v_line.back_porch;
    return h_total * v_total;
  endfunction

  /** @brief Vráti horizontálne rozlíšenie (viditeľnú oblasť) pre zvolený VGA režim */
  function automatic int get_h_res(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.h_line.visible_area;
  endfunction
  /** @brief Vráti horizontálne FP pre zvolený VGA režim */
  function automatic int get_h_fp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.h_line.front_porch;
  endfunction
  /** @brief Vráti horizontálne SP pre zvolený VGA režim */
  function automatic int get_h_sp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.h_line.sync_pulse;
  endfunction
  /** @brief Vráti horizontálne BP pre zvolený VGA režim */
  function automatic int get_h_bp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.h_line.back_porch;
  endfunction
  /** @brief Vráti horizontálne SYNC POLARITY pre zvolený VGA režim */
  function automatic int get_h_pol(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.h_line.polarity;
  endfunction

  /** @brief Vráti vertikálne rozlíšenie (viditeľnú oblasť) pre zvolený VGA režim */
  function automatic int get_v_res(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.v_line.visible_area;
  endfunction
  /** @brief Vráti vertikálne FP pre zvolený VGA režim */
  function automatic int get_v_fp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.v_line.front_porch;
  endfunction
  /** @brief Vráti vertikálne SP pre zvolený VGA režim */
  function automatic int get_v_sp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.v_line.sync_pulse;
  endfunction
  /** @brief Vráti vertikálne BP pre zvolený VGA režim */
  function automatic int get_v_bp(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.v_line.back_porch;
  endfunction
  /** @brief Vráti vertikálne SYNC POLARITY pre zvolený VGA režim */
  function automatic int get_v_pol(input vga_mode_e mode);
    vga_params_t temp_params = get_vga_params(mode);
    return temp_params.v_line.polarity;
  endfunction

`endif

endpackage : vga_pkg

`endif // VGA_PKG_DONE
