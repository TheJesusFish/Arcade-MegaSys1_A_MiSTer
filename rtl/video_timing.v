
module video_timing
(
    input       clk,
    input       clk_pix,
    input       reset,

    input        refresh_mod,

    input  signed [3:0] hs_offset,
    input  signed [3:0] vs_offset,

    input  signed [3:0] hs_width,
    input  signed [3:0] vs_width,

    output [8:0] hc,
    output [8:0] vc,

    output reg  hsync,
    output reg  vsync,

    output reg  hbl,
    output reg  vbl
);

// Sync adjustments sign-extended to the 9-bit counters.
wire [8:0] hs_ofs9    = { {5{hs_offset[3]}}, hs_offset };
wire [8:0] hs_wid9    = { {5{hs_width[3]}},  hs_width  };
wire [8:0] vs_ofs9    = { {5{vs_offset[3]}}, vs_offset };
wire [8:0] vs_wid9    = { {5{vs_width[3]}},  vs_width  };

wire [8:0] h_ofs = 0;
wire [8:0] HBL_START  = 255;
wire [8:0] HBL_END    = 383;
wire [8:0] HS_START   = HBL_START + 9'd41 + hs_ofs9;
wire [8:0] HS_END     = HBL_START + 9'd66 + hs_ofs9 + hs_wid9;
wire [8:0] HTOTAL     = 383;

wire [8:0] v_ofs = 0;
wire [8:0] VBL_START  = 240;
wire [8:0] VBL_END    = 16;
wire [8:0] VTOTAL     = ( refresh_mod ? 9'd262 : 9'd277 );
wire [8:0] VS_START   = VBL_START + 9'd13 + vs_ofs9;
// Vsync pulse at least one line long, ending in the next frame if it runs past the last line.
wire [8:0] VS_LEN     = ( vs_width == 4'b1000 ) ? 9'd1 : 9'd8 + vs_wid9;
wire [8:0] VS_END_RAW = VS_START + VS_LEN;
wire [8:0] VS_END     = ( VS_END_RAW > VTOTAL ) ? VS_END_RAW - VTOTAL - 9'd1 : VS_END_RAW;


reg [8:0] v;
reg [8:0] h;

assign vc = v - v_ofs;
assign hc = h - h_ofs;

always @ (posedge clk) begin
    if (reset) begin
        h <= 0;
        v <= 0;

        hbl <= 0;
        vbl <= 0;

        hsync <= 0;
        vsync <= 0;
    end else if ( clk_pix == 1 ) begin
        // counter
        if ( h == HTOTAL ) begin
            h <= 0;
            v <= v + 1'd1;

            if ( v == VTOTAL ) begin
                v <= 0;
            end
        end else begin
            h <= h + 1'd1;
        end

        // h signals
        if ( h == HBL_START ) begin
            hbl <= 1;
        end else if ( h == HBL_END ) begin
            hbl <= 0;
        end

        // v signals
        if ( v == VBL_START ) begin
            vbl <= 1;
        end else if ( v == VBL_END ) begin
            vbl <= 0;
        end

        if ( v == (VS_START ) ) begin
            vsync <= 1;
        end else if ( v == (VS_END ) ) begin
            vsync <= 0;
        end

        if ( h == (HS_START ) ) begin
            hsync <= 1;
        end else if ( h == (HS_END ) ) begin
            hsync <= 0;
        end
    end

end

endmodule

