`ifndef VIDEO_PKG_SV
`define VIDEO_PKG_SV

package video_pkg;

    typedef struct packed {
        logic [4:0] red;
        logic [5:0] grn;
        logic [4:0] blu;
    } rgb565_t;

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
