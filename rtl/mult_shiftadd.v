// ============================================================================
// mult_shiftadd.v - Baseline B: sequential shift-and-add 32x32 -> 64 multiplier
// ============================================================================
//
// Radix-2, one multiplier bit per clock, a single 32-bit adder.
//
// Datapath: {acc, q} is a 64-bit shift register. q starts as the multiplier
// and is consumed from its LSB; product bits enter q from the top. Each
// iteration:
//
//     sum      = acc + (q[0] ? mcand : 0)          (33 bits incl. carry)
//     {acc, q} = {sum, q} >> 1
//
// After 32 iterations {acc, q} holds the 64-bit unsigned product.
//
// Timing (cycle = rising edge; edge k is the one that samples valid_in):
//
//     edge k          load operands and perform iteration 0 (q[0] of the
//                     multiplier is b's LSB, available directly)
//     edges k+1..k+31 iterations 1..31
//     edge k+32       sign fix, register p, raise valid_out
//
//   -> latency 33 cycles from valid_in to valid_out: 32 add/shift steps
//      plus one registered sign-fix / output cycle. The 64-bit negation is
//      kept in its own cycle so it does not sit in series with the adder.
//
// Throughput: one multiplication at a time. A new operand pair is accepted
// only when the unit is idle, i.e. from edge k+33 on (initiation interval
// 33 cycles). The common interface has no ready/backpressure signal, so
// valid_in asserted while busy is IGNORED - the caller must wait for
// valid_out (the testbench uses +WAIT for this module).
//
// PIPE_STAGES is accepted for interface compatibility and is unused.
//
// ---------------------------------------------------------------------------
// SIGNED_MODE = 1: sign-magnitude
// ---------------------------------------------------------------------------
//
//   neg  = a[31] ^ b[31]
//   |a|  = a[31] ? -a : a,   |b| likewise
//   P    = |a| * |b|                    (unsigned shift-add above)
//   p    = neg ? -P : P                 (64-bit two's complement)
//
// Corner case a = b = 0x80000000 (-2^31): the negation is done on 33-bit
// sign-extended operands, so -(-2^31) = +2^31 = 33'h0_8000_0000 is exact
// (in 32 bits it would wrap back to 0x80000000 and only be "right" by
// accident of reinterpretation). The magnitude of a 32-bit signed value is
// at most 2^31, so bit 32 of the 33-bit magnitude is always 0 and the
// magnitude registers keep bits [31:0] only. P is then at most 2^62
// (min * min = +2^62 = 0x4000_0000_0000_0000), which fits the 64-bit
// product, and -P is at least -2^62, so the final negation never overflows.
// ============================================================================

`timescale 1ns/1ps

module mult_shiftadd #(
    parameter SIGNED_MODE = 0,
    parameter PIPE_STAGES = 2          // unused, see header
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [63:0] p,
    output wire        valid_out
);

    // ------------------------------------------------------------------
    // Operand magnitudes (33-bit intermediates, see header)
    // ------------------------------------------------------------------
    wire        a_neg = (SIGNED_MODE != 0) && a[31];
    wire        b_neg = (SIGNED_MODE != 0) && b[31];
    wire [32:0] a_x   = {a_neg, a};                 // 33-bit sign extension
    wire [32:0] b_x   = {b_neg, b};
    wire [32:0] a_mag = a_neg ? (33'd0 - a_x) : a_x;
    wire [32:0] b_mag = b_neg ? (33'd0 - b_x) : b_x;
    // a_mag[32] and b_mag[32] are always 0 (|x| <= 2^31).

    // ------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------
    reg        busy;                    // iterations 1..31 in progress
    reg        fix;                     // sign-fix / output cycle
    reg  [4:0] cnt;                     // iterations left after this one
    reg        v_r;

    wire idle  = !busy && !fix;
    wire start = idle && valid_in;

    // ------------------------------------------------------------------
    // Datapath
    // ------------------------------------------------------------------
    reg  [31:0] mcand;                  // |a|
    reg  [31:0] acc;                    // upper product half / partial sum
    reg  [31:0] q;                      // multiplier, then lower product half
    reg         neg;                    // result sign
    reg  [63:0] p_r;

    // Iteration 0, done while loading: acc = 0 and the multiplier LSB is
    // b_mag[0] (= b[0], negation does not change bit 0).
    wire [32:0] sum0 = b_mag[0] ? {1'b0, a_mag[31:0]} : 33'd0;
    // Iterations 1..31
    wire [32:0] sum  = {1'b0, acc} + (q[0] ? {1'b0, mcand} : 33'd0);

    wire [63:0] prod = {acc, q};

    always @(posedge clk) begin
        if (start) begin
            mcand <= a_mag[31:0];
            acc   <= sum0[32:1];
            q     <= {sum0[0], b_mag[31:1]};
            neg   <= a_neg ^ b_neg;
        end else if (busy) begin
            acc   <= sum[32:1];
            q     <= {sum[0], q[31:1]};
        end

        if (fix)
            p_r <= neg ? (64'd0 - prod) : prod;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            fix  <= 1'b0;
            cnt  <= 5'd0;
            v_r  <= 1'b0;
        end else begin
            v_r <= fix;
            fix <= busy && (cnt == 5'd1);
            if (start) begin
                busy <= 1'b1;
                cnt  <= 5'd31;
            end else if (busy) begin
                cnt <= cnt - 5'd1;
                if (cnt == 5'd1) busy <= 1'b0;
            end
        end
    end

    assign p         = p_r;
    assign valid_out = v_r;

endmodule
