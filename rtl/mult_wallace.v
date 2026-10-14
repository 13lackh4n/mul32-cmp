// ============================================================================
// mult_wallace.v - 32x32 -> 64 Wallace-tree multiplier in fabric logic only
// ============================================================================
//
// (* use_dsp = "no" *) is set on this module and on every partial-product /
// carry-save signal: without it Vivado may rebuild the multiply on DSP48E1
// slices and the LUT-tree measurement would be meaningless. The final
// carry-propagate adder (CPA) lives in its own submodule without the
// attribute; a '+' maps to the CARRY4 chain, which is what is wanted.
//
// ---------------------------------------------------------------------------
// Partial products, USE_BOOTH = 0  (32 rows)
// ---------------------------------------------------------------------------
//   pp[i] = a & {32{b[i]}}          (AND gates), row weight 2^i
//
//   SIGNED_MODE = 1 uses the modified Baugh-Wooley form, which keeps the
//   row count at 32 (no extra correction row):
//     - invert pp bit j of row i when exactly one of i, j is 31
//       (row 31: bits 0..30 inverted; rows 0..30: bit 31 inverted)
//     - add the constant 2^32 + 2^63, placed in the empty bits 32 and 63
//       of row 0
//   The result is the two's-complement product modulo 2^64.
//
//   Reduction (3:2 CSA, rows per level):
//     level :  0    1    2    3    4    5    6    7    8
//     rows  : 32 -> 22 -> 15 -> 10 -> 7 -> 5 -> 4 -> 3 -> 2
//   Each level groups the rows in threes; each group becomes a sum row
//   and a carry row (shifted left by 1); 1 or 2 leftover rows pass through.
//
// ---------------------------------------------------------------------------
// Partial products, USE_BOOTH = 1  (Booth radix-4, 17 rows)
// ---------------------------------------------------------------------------
//   a is extended to 35 bits (sign- or zero-extended per SIGNED_MODE) so
//   that +/-2a fits. b is extended to {b33, b32, b[31:0], b_-1 = 0}
//   (b32, b33 = sign bit or 0), giving 17 overlapping 3-bit groups
//   (b[2i+1], b[2i], b[2i-1]), i = 0..16, digit d_i in {-2,-1,0,+1,+2}:
//
//     x1  = b[2i] ^ b[2i-1]                              |d| = 1
//     x2  = b[2i+1]&~b[2i]&~b[2i-1] | ~b[2i+1]&b[2i]&b[2i-1]  |d| = 2
//     neg = b[2i+1] & ~(b[2i] & b[2i-1])                 d < 0
//
//     m_i = x1 ? a : x2 ? {a, 1'b0} : 0     (+2a is the 1-bit left shift,
//                                            not a multiply)
//     v_i = m_i ^ {35{neg}}                 one's complement; the +1 (neg_i)
//                                           goes in the empty bit 2i of
//                                           row i+1
//   The group 111 is decoded as d = 0 with neg = 0, so neg_16 is always 0
//   (group 16 is 000/111 when signed, 00x when unsigned) and needs no slot.
//
//   Sign extension is not replicated: with s_i = v_i[34],
//     sign_ext(v_i) = v_i[33:0] + ~s_i * 2^34 - 2^34
//   Row i >= 1 carries {~s_i, v_i[33:0]} at weight 2^(2i). The constants
//   -2^(34+2i) of all rows sum to C = 0xAAAAAAAC_00000000 (mod 2^64), which
//   is folded together with row 0's ~s_0 term into the upper bits of row 0:
//     row0[63:34] = s_0 ? C[63:34] : (C + 2^34)[63:34]
//   so the row count stays 17.
//
//   Reduction (3:2 CSA, rows per level):
//     level :  0    1    2   3   4   5   6
//     rows  : 17 -> 12 -> 8 -> 6 -> 4 -> 3 -> 2
//
// ---------------------------------------------------------------------------
// Final CPA: s = row0 + row1 (64-bit, CARRY4 chain), then output register.
// ---------------------------------------------------------------------------
//
// Pipeline (latency = PIPE_STAGES, fully pipelined):
//   stage 1               input registers
//   PIPE_STAGES - 2 = R   internal registers at CSA level boundaries
//   last stage            output register after the CPA
//
//   Placement of the R internal registers (NLVL = number of CSA levels,
//   8 without Booth, 6 with Booth; "after level 0" = after PP generation):
//     - if R >= 1: one after the last CSA level, i.e. in front of the CPA
//     - the other R-1 after levels floor(j*(NLVL+1)/R) - 1, j = 1..R-1,
//       which splits PP generation + CSA levels into R nearly equal parts
//   PIPE_STAGES range: 2 .. NLVL+3.
//
//   Default PIPE_STAGES = 4 (R = 2):
//     USE_BOOTH=0: in | PP, L1..L3 | L4..L8 | CPA | out
//     USE_BOOTH=1: in | PP, L1..L2 | L3..L6 | CPA | out
//
// Data registers have no reset; only the valid chain is reset
// (synchronous, active low).
// ============================================================================

`timescale 1ns/1ps

(* use_dsp = "no" *)
module mult_wallace #(
    parameter SIGNED_MODE = 0,
    parameter PIPE_STAGES = 4,
    parameter USE_BOOTH   = 0
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
    // Tree geometry (elaboration-time)
    // ------------------------------------------------------------------
    localparam integer NPP = (USE_BOOTH != 0) ? 17 : 32;

    // Rows remaining after 'lvl' 3:2 levels.
    function integer rows_after;
        input integer n0;
        input integer lvl;
        integer k, n;
        begin
            n = n0;
            for (k = 0; k < lvl; k = k + 1)
                if (n > 2) n = (n / 3) * 2 + (n % 3);
            rows_after = n;
        end
    endfunction

    // Number of 3:2 levels needed to reach 2 rows.
    function integer num_levels;
        input integer n0;
        integer k, n, c;
        begin
            n = n0;
            c = 0;
            for (k = 0; k < 64; k = k + 1)
                if (n > 2) begin
                    n = (n / 3) * 2 + (n % 3);
                    c = c + 1;
                end
            num_levels = c;
        end
    endfunction

    localparam integer NLVL = num_levels(NPP);
    localparam integer NREG = PIPE_STAGES - 2;    // internal register stages

    // 1 if a pipeline register follows CSA level k (k = 0: after PP gen).
    function integer reg_after;
        input integer k;
        integer j;
        begin
            reg_after = 0;
            if (NREG > 0) begin
                if (k == NLVL) reg_after = 1;
                for (j = 1; j < NREG; j = j + 1)
                    if ((j * (NLVL + 1)) / NREG - 1 == k) reg_after = 1;
            end
        end
    endfunction

    generate
        if (PIPE_STAGES < 2 || PIPE_STAGES > NLVL + 3) begin : g_bad_param
            PIPE_STAGES_out_of_range u_err ();
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
    // Partial-product rows: NPP x 64 bits, row k at pp_rows[64*k +: 64]
    // ------------------------------------------------------------------
    (* use_dsp = "no" *) wire [64*NPP-1:0] pp_rows;

    genvar i;
    generate
        if (USE_BOOTH == 0) begin : g_pp_and
            for (i = 0; i < 32; i = i + 1) begin : g_row
                // AND-gate partial product
                (* use_dsp = "no" *) wire [31:0] pp = a_r & {32{b_r[i]}};
                // Baugh-Wooley inversions (signed only)
                wire [31:0] bw_inv = (SIGNED_MODE == 0) ? 32'h0000_0000 :
                                     (i == 31)          ? 32'h7FFF_FFFF :
                                                          32'h8000_0000;
                (* use_dsp = "no" *) wire [63:0] row = {32'd0, pp ^ bw_inv} << i;
                // Baugh-Wooley constant 2^32 + 2^63 in the free bits of row 0
                wire [63:0] bw_const = (SIGNED_MODE != 0 && i == 0) ?
                                       64'h8000_0001_0000_0000 : 64'd0;
                assign pp_rows[64*i +: 64] = row | bw_const;
            end
        end else begin : g_pp_booth
            wire        sa = (SIGNED_MODE != 0) && a_r[31];
            wire        sb = (SIGNED_MODE != 0) && b_r[31];
            wire [34:0] a1 = {{3{sa}}, a_r};          // +a, 35-bit extended
            wire [34:0] a2 = {a1[33:0], 1'b0};        // +2a = {a, 1'b0}
            wire [34:0] bb = {sb, sb, b_r, 1'b0};     // {b33, b32, b, b_-1}

            // Sum of the per-row sign-extension constants -2^(34+2i).
            localparam [63:0] BOOTH_C  = 64'hAAAA_AAAC_0000_0000;
            localparam [63:0] BOOTH_C0 = BOOTH_C + 64'h0000_0004_0000_0000;

            wire [16:0] neg_v;

            for (i = 0; i < 17; i = i + 1) begin : g_row
                wire bm1 = bb[2*i];
                wire b0  = bb[2*i+1];
                wire b1  = bb[2*i+2];
                wire x1  = b0 ^ bm1;
                wire x2  = (b1 & ~b0 & ~bm1) | (~b1 & b0 & bm1);
                wire neg = b1 & ~(b0 & bm1);
                assign neg_v[i] = neg;

                (* use_dsp = "no" *) wire [34:0] m = ({35{x1}} & a1) | ({35{x2}} & a2);
                (* use_dsp = "no" *) wire [34:0] v = m ^ {35{neg}};
                wire s = v[34];

                if (i == 0) begin : g_first
                    assign pp_rows[0 +: 64] =
                        {(s ? BOOTH_C[63:34] : BOOTH_C0[63:34]), v[33:0]};
                end else begin : g_rest
                    (* use_dsp = "no" *) wire [63:0] row =
                        ({29'd0, ~s, v[33:0]} << (2*i)) |
                        ({63'd0, neg_v[i-1]}  << (2*(i-1)));
                    assign pp_rows[64*i +: 64] = row;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // 3:2 CSA tree. Level L holds rows_after(NPP, L) rows; level L's rows
    // are at lvl_d / lvl_q[64*NPP*L +: 64*N] (unused upper rows are 0).
    //   lvl_d : combinational output of level L
    //   lvl_q : the same after the optional pipeline register
    // ------------------------------------------------------------------
    localparam integer LW = 64 * NPP;

    (* use_dsp = "no" *) wire [LW*(NLVL+1)-1:0] lvl_d;
    (* use_dsp = "no" *) wire [LW*(NLVL+1)-1:0] lvl_q;

    genvar L, g;
    generate
        for (L = 0; L <= NLVL; L = L + 1) begin : g_lvl
            localparam integer N = rows_after(NPP, L);

            if (L == 0) begin : g_src
                assign lvl_d[0 +: LW] = pp_rows;
            end else begin : g_csa
                localparam integer NP  = rows_after(NPP, L - 1);
                localparam integer G   = NP / 3;
                localparam integer REM = NP % 3;
                localparam integer IB  = LW * (L - 1);      // input base
                localparam integer OB  = LW * L;            // output base

                for (g = 0; g < G; g = g + 1) begin : g_grp
                    wire [63:0] x = lvl_q[IB + 64*(3*g)     +: 64];
                    wire [63:0] y = lvl_q[IB + 64*(3*g + 1) +: 64];
                    wire [63:0] z = lvl_q[IB + 64*(3*g + 2) +: 64];
                    (* use_dsp = "no" *) wire [63:0] cs_s = x ^ y ^ z;
                    (* use_dsp = "no" *) wire [63:0] cs_c = (x & y) | (x & z) | (y & z);
                    assign lvl_d[OB + 64*(2*g)     +: 64] = cs_s;
                    assign lvl_d[OB + 64*(2*g + 1) +: 64] = {cs_c[62:0], 1'b0};
                end
                if (REM != 0) begin : g_pass
                    assign lvl_d[OB + 64*(2*G) +: 64*REM] = lvl_q[IB + 64*(3*G) +: 64*REM];
                end
            end

            if (N < NPP) begin : g_unused
                assign lvl_d[LW*L + 64*N +: 64*(NPP - N)] = {64*(NPP - N){1'b0}};
            end

            if (reg_after(L) != 0) begin : g_reg
                (* use_dsp = "no" *) reg [64*N-1:0] r;
                always @(posedge clk) r <= lvl_d[LW*L +: 64*N];
                assign lvl_q[LW*L +: 64*N] = r;
            end else begin : g_wire
                assign lvl_q[LW*L +: 64*N] = lvl_d[LW*L +: 64*N];
            end
            if (N < NPP) begin : g_unused_q
                assign lvl_q[LW*L + 64*N +: 64*(NPP - N)] = {64*(NPP - N){1'b0}};
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Final CPA + output register
    // ------------------------------------------------------------------
    wire [63:0] cpa_s;

    wallace_cpa u_cpa (
        .x (lvl_q[LW*NLVL      +: 64]),
        .y (lvl_q[LW*NLVL + 64 +: 64]),
        .s (cpa_s)
    );

    reg [63:0] p_r;
    always @(posedge clk) p_r <= cpa_s;
    assign p = p_r;

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
// wallace_cpa - final 64-bit carry-propagate adder. Deliberately without
// use_dsp = "no": a plain '+' maps to the CARRY4 chain.
// ----------------------------------------------------------------------------
module wallace_cpa (
    input  wire [63:0] x,
    input  wire [63:0] y,
    output wire [63:0] s
);
    assign s = x + y;
endmodule
