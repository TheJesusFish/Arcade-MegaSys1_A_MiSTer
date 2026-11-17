// Three-channel signed audio mixer with 4.4 fixed-point gains and 16-bit saturation.
module megasys1_mixer #(
    parameter W0 = 16,
    parameter W1 = 16,
    parameter W2 = 16
) (
    input                    rst,
    input                    clk,
    input  signed [W0-1:0]   ch0,
    input  signed [W1-1:0]   ch1,
    input  signed [W2-1:0]   ch2,
    input         [7:0]      gain0,
    input         [7:0]      gain1,
    input         [7:0]      gain2,
    output signed [15:0]     mixed
);

// Inputs left-justified to 16 bits.
wire signed [15:0] s0 = { ch0, {16-W0{1'b0}} };
wire signed [15:0] s1 = { ch1, {16-W1{1'b0}} };
wire signed [15:0] s2 = { ch2, {16-W2{1'b0}} };

// Gains as positive 9-bit signed values.
wire signed [8:0] g0 = { 1'b0, gain0 };
wire signed [8:0] g1 = { 1'b0, gain1 };
wire signed [8:0] g2 = { 1'b0, gain2 };

reg  signed [23:0] p0, p1, p2;
reg  signed [25:0] psum;
reg  signed [15:0] sum;

// Sum without the 4 fractional gain bits.
wire signed [21:0] pint = psum[25:4];
wire               peak = pint[21:16] != {6{pint[15]}};

always @(posedge clk) begin
    p0   <= g0 * s0;
    p1   <= g1 * s1;
    p2   <= g2 * s2;
    psum <= { {2{p0[23]}}, p0 } + { {2{p1[23]}}, p1 } + { {2{p2[23]}}, p2 };
end

// Saturate to 16 bits; reset halves the output each clock.
always @(posedge clk) begin
    if (rst)
        sum <= sum >>> 1;
    else if (peak)
        sum <= pint[21] ? 16'sh8000 : 16'sh7fff;
    else
        sum <= pint[15:0];
end

assign mixed = sum;

endmodule
