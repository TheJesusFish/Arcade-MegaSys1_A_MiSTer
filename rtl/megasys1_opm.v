//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

module megasys1_opm
(
    input                rst,
    input                clk,
    input                cen,
    input                cs_n,
    input                wr_n,
    input                a0,
    input          [7:0] din,
    output         [7:0] dout,
    output               irq_n,
    output signed [15:0] left,
    output signed [15:0] right
);

wire read_n = cs_n | ~wr_n;

// Register the enable before its high-fanout path through IKAOPM.
(* preserve *) reg cen_q = 1'b0;

always @(posedge clk) begin
    if (rst)
        cen_q <= 1'b0;
    else
        cen_q <= cen;
end

IKAOPM #(
    .FULLY_SYNCHRONOUS(1),
    .FAST_RESET(1),
    .USE_BRAM(1)
) u_opm (
    .i_EMUCLK(clk),
    .i_phiM_PCEN_n(~cen_q),
    .i_IC_n(~rst),
    .o_phi1(),
    .i_CS_n(cs_n),
    .i_RD_n(read_n),
    .i_WR_n(wr_n),
    .i_A0(a0),
    .i_D(din),
    .o_D(dout),
    .o_D_OE(),
    .o_CT2(),
    .o_CT1(),
    .o_IRQ_n(irq_n),
    .o_SH1(),
    .o_SH2(),
    .o_SO(),
    .o_EMU_R_SAMPLE(),
    .o_EMU_R_EX(),
    .o_EMU_R(right),
    .o_EMU_L_SAMPLE(),
    .o_EMU_L_EX(),
    .o_EMU_L(left)
);

endmodule
