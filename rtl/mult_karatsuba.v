// ============================================================================
// mult_karatsuba.v - 32x32 -> 64 Karatsuba multiplier, one level, 3 DSP48E1
// ============================================================================
//
//   a = a1 * 2^16 + a0          b = b1 * 2^16 + b0
//
//   z0 = a0 * b0
//   z2 = a1 * b1
//   z1 = (a0 + a1) * (b0 + b1) - z0 - z2       (= a1*b0 + a0*b1)
//   p  = z2 * 2^32 + z1 * 2^16 + z0
//
// ---------------------------------------------------------------------------
// Operand handling
// ---------------------------------------------------------------------------
// Every half is extended to a 17-bit SIGNED value so that one set of signed
// arithmetic serves both modes:
//
//   a0x = {1'b0, a[15:0]}                         low half: always unsigned
//   a1x = {SIGNED_MODE ? a[31] : 1'b0, a[31:16]}  high half: signed in
//                                                 SIGNED_MODE=1, else unsigned
//   (b likewise)
//
// This is exact: in two's complement a = (signed a[31:16]) * 2^16
// + (unsigned a[15:0]); unsigned a is the same with an unsigned high half.
//
// Value ranges (all checked against the DSP48E1 25x18 signed multiplier):
//
//   quantity      SIGNED_MODE=1                 SIGNED_MODE=0
//   a0, b0        [0, 65535]                    [0, 65535]
//   a1, b1        [-32768, 32767]               [0, 65535]
//   a0 + a1       [-32768, 98302]               [0, 131070]
//
//   The pre-adder sums are therefore 18-bit signed values, NOT 17-bit:
//   +98302 > 2^16 - 1 = 65535, the 17-bit signed maximum (e.g. a0 = 0xFFFF,
//   a1 = 0x7FFF). Both ranges fit 18-bit signed [-131072, +131071], which is
//   exactly the DSP48E1 B-port width, so (a0+a1)*(b0+b1) is an 18x18 signed
//   multiply = one DSP48E1 (A port 25 bits, B port 18 bits).
//
//   z0  = a0x * b0x : 17x17 signed, value in [0, (2^16-1)^2]        1 DSP
//         -> fits 32 bits unsigned
//   z2  = a1x * b1x : 17x17 signed, value in [-2^30+2^15, 2^30]     1 DSP
//         (signed) or [0, (2^16-1)^2] (unsigned) -> fits 32 bits
//   mid = sa * sb   : 18x18 signed -> 36-bit signed                 1 DSP
//         signed:   [-32768*98302, 98302^2]  = [-3.22e9, 9.66e9]
//         unsigned: [0, 131070^2]            = [0, 1.72e10] < 2^34
//   z1  = mid - z0 - z2 = a1*b0 + a0*b1
//         signed:   [-4294901760, 4294770690]  (about +/-2^32)
//         unsigned: [0, 8589672450]            (< 2^33)
//         -> 36-bit signed is ample.
//
//   In SIGNED_MODE=0 the sums are 17-bit unsigned [0, 131070], i.e. the
//   middle product is a 17x17 unsigned multiply carried in 18x18 signed
//   form (zero-extended), still one DSP48E1.
//   (Ranges above were checked numerically at the operand extremes; every
//   product/sum is bilinear in the operands, so extremes lie at corners.)
//
// Final sum: z0 < 2^32 occupies bits [31:0] and z2 * 2^32 bits [63:32], so
// z2 * 2^32 + z0 is a plain concatenation {z2[31:0], z0[31:0]} (exact
// modulo 2^64 in both modes). Only z1 * 2^16 is really added:
//
//   p = {z2[31:0], z0[31:0]} + (sign_extend_64(z1) << 16)
//
// The result is exact modulo 2^64, i.e. the correct 64-bit unsigned or
// two's-complement product.
//
// ---------------------------------------------------------------------------
// Pipeline (latency = PIPE_STAGES, fully pipelined, 1 result/cycle)
// ---------------------------------------------------------------------------
//   stage 1  input registers a_r, b_r
//   stage 2  pre-adders + three multiplies -> z0, z2, mid registers
//   (PIPE_STAGES-4 extra product register stages, default none: they let
//    Vivado use both the DSP48E1 MREG and PREG)
//   stage 3  subtract chain z1 = mid - z0 - z2 (own stage, so it does not
//            limit fmax); z0, z2 delayed alongside
//   stage 4  final 64-bit add -> p
//
// Data registers have no reset (required for DSP register packing); only the
// valid chain is reset (synchronous, active low).
// ============================================================================

`timescale 1ns/1ps

module mult_karatsuba #(
    parameter SIGNED_MODE = 0,
    parameter PIPE_STAGES = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [63:0] p,
    output wire        valid_out
);

    localparam EXTRA = PIPE_STAGES - 4;     // extra product register stages

    generate
        if (PIPE_STAGES < 4) begin : g_bad_param
            PIPE_STAGES_must_be_at_least_4 u_err ();
        end
    endgenerate

    // ------------------------------------------------------------------
    // Stage 1: input registers
    // ------------------------------------------------------------------
    reg [31:0] a_r, b_r;

    always @(posedge clk) begin
        a_r <= a;
        b_r <= b;
    end

    // ------------------------------------------------------------------
    // Stage 2: halves, pre-adders, three DSP multiplies
    // ------------------------------------------------------------------
    wire sx_a = (SIGNED_MODE != 0) && a_r[31];
    wire sx_b = (SIGNED_MODE != 0) && b_r[31];

    wire signed [16:0] a0x = {1'b0, a_r[15:0]};
    wire signed [16:0] b0x = {1'b0, b_r[15:0]};
    wire signed [16:0] a1x = {sx_a, a_r[31:16]};
    wire signed [16:0] b1x = {sx_b, b_r[31:16]};

    // 18-bit signed sums (see range table in the header).
    wire signed [17:0] sa = a0x + a1x;
    wire signed [17:0] sb = b0x + b1x;

    wire signed [33:0] z0_w, z2_w;
    wire signed [35:0] mid_w;

    kara_dsp_mul #(.WA(17), .WB(17)) u_mul_z0  (.x(a0x), .y(b0x), .z(z0_w));
    kara_dsp_mul #(.WA(17), .WB(17)) u_mul_z2  (.x(a1x), .y(b1x), .z(z2_w));
    kara_dsp_mul #(.WA(18), .WB(18)) u_mul_mid (.x(sa),  .y(sb),  .z(mid_w));

    // Product registers: index 0 is the stage-2 register, 1..EXTRA the
    // optional extra stages.
    reg signed [33:0] z0_q  [0:EXTRA];
    reg signed [33:0] z2_q  [0:EXTRA];
    reg signed [35:0] mid_q [0:EXTRA];
    integer i;

    always @(posedge clk) begin
        z0_q[0]  <= z0_w;
        z2_q[0]  <= z2_w;
        mid_q[0] <= mid_w;
        for (i = 1; i <= EXTRA; i = i + 1) begin
            z0_q[i]  <= z0_q[i-1];
            z2_q[i]  <= z2_q[i-1];
            mid_q[i] <= mid_q[i-1];
        end
    end

    wire signed [33:0] z0_2  = z0_q[EXTRA];
    wire signed [33:0] z2_2  = z2_q[EXTRA];
    wire signed [35:0] mid_2 = mid_q[EXTRA];

    // ------------------------------------------------------------------
    // Stage 3: subtract chain
    // ------------------------------------------------------------------
    reg signed [35:0] z1_3;
    reg        [31:0] z0_3, z2_3;           // only the low 32 bits are needed

    always @(posedge clk) begin
        z1_3 <= mid_2 - z0_2 - z2_2;
        z0_3 <= z0_2[31:0];
        z2_3 <= z2_2[31:0];
    end

    // ------------------------------------------------------------------
    // Stage 4: final accumulate
    // ------------------------------------------------------------------
    reg [63:0] p_4;

    always @(posedge clk)
        p_4 <= {z2_3, z0_3} + {{12{z1_3[35]}}, z1_3, 16'd0};

    assign p = p_4;

    // ------------------------------------------------------------------
    // Valid chain
    // ------------------------------------------------------------------
    reg [PIPE_STAGES-1:0] v_r;

    always @(posedge clk) begin
        if (!rst_n) v_r <= {PIPE_STAGES{1'b0}};
        else        v_r <= {v_r[PIPE_STAGES-2:0], valid_in};
    end

    assign valid_out = v_r[PIPE_STAGES-1];

endmodule


// ----------------------------------------------------------------------------
// kara_dsp_mul - one signed sub-multiply, forced onto a DSP48E1.
// The attribute is placed here rather than on mult_karatsuba so that it does
// not also force the fabric adders/subtractors into DSP blocks.
// ----------------------------------------------------------------------------
(* use_dsp = "yes" *)
module kara_dsp_mul #(
    parameter WA = 17,
    parameter WB = 17
)(
    input  wire signed [WA-1:0]    x,
    input  wire signed [WB-1:0]    y,
    output wire signed [WA+WB-1:0] z
);
    assign z = x * y;
endmodule
