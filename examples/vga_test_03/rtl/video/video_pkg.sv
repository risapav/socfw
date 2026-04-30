/**
 * @file video_pkg.sv
 * @brief Balík definícií pre video spracovanie v RGB565 formáte.
 * @details Obsahuje štruktúru pixelu a základné farebné konštanty.
 */

`ifndef VIDEO_PKG_SV
`define VIDEO_PKG_SV

package video_pkg;

/**
   * @struct rgb565_t
   * @brief Reprezentácia pixelu v 16-bitovom formáte (5-R, 6-G, 5-B).
   */
  typedef struct packed {
    logic [4:0] red;
    logic [5:0] grn;
    logic [4:0] blu;
  } rgb565_t;

  // Definície základných farieb pre generátory a defaultné stavy
  localparam rgb565_t BLACK    = '{red:5'h00, grn:6'h00, blu:5'h00};
  localparam rgb565_t WHITE    = '{red:5'h1F, grn:6'h3F, blu:5'h1F};
  localparam rgb565_t RED      = '{red:5'h1F, grn:6'h00, blu:5'h00};
  localparam rgb565_t GREEN    = '{red:5'h00, grn:6'h3F, blu:5'h00};
  localparam rgb565_t BLUE     = '{red:5'h00, grn:6'h00, blu:5'h1F};
  localparam rgb565_t YELLOW   = '{red:5'h1F, grn:6'h3F, blu:5'h00};
  localparam rgb565_t CYAN     = '{red:5'h00, grn:6'h3F, blu:5'h1F};
  localparam rgb565_t PURPLE   = '{red:5'h1F, grn:6'h00, blu:5'h1F};
  localparam rgb565_t ORANGE   = '{red:5'h1F, grn:6'h20, blu:5'h00};
  localparam rgb565_t DARKGRAY = '{red:5'h04, grn:6'h08, blu:5'h04};

endpackage

`endif
