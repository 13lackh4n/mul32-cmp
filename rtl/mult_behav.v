// ============================================================================
// mult_behav.v - Baseline A: behavioral 32x32 -> 64 multiplier (p = a * b)
// ============================================================================
//
// The multiply is written as a single '*' and left to Vivado, which maps it
// onto DSP48E1 slices (forced with use_dsp = "yes").
//
// Pipeline (latency = PIPE_STAGES cycles, fully pipelined, 1 result/cycle):
//
//   stage 1            : input registers a_r, b_r
//   stages 2..PIPE_STAGES : product registers p_r[1..PIPE_STAGES-1]
//
// The product registers carry no reset and sit directly behind the
// multiplier, so Vivado may pull them into the DSP48E1 MREG/PREG and cascade
// registers. PIPE_STAGES = 2 is the plain "input + output register" baseline;
// larger values give the tool more registers to absorb.
//
// Only the valid chain is reset (synchronous, active low); data registers
// are not reset, which DSP48 inference requires for clean register packing.
// ============================================================================

`timescale 1ns/1ps

(* use_dsp = "yes" *)
module mult_behav #(
    parameter SIGNED_MODE = 0,
    parameter PIPE_STAGES = 2
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [63:0] p,
    output wire        valid_out
);

    // PIPE_STAGES < 2 cannot hold both the input and the output register.
    generate
        if (PIPE_STAGES < 2) begin : g_bad_param
            PIPE_STAGES_must_be_at_least_2 u_err ();
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
    // Multiply
    // ------------------------------------------------------------------
    wire [63:0] prod;

    generate
        if (SIGNED_MODE != 0) begin : g_signed
            assign prod = $signed(a_r) * $signed(b_r);
        end else begin : g_unsigned
            assign prod = a_r * b_r;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Stages 2..PIPE_STAGES: product registers
    // ------------------------------------------------------------------
    reg [63:0] p_r [1:PIPE_STAGES-1];
    integer i;

    always @(posedge clk) begin
        p_r[1] <= prod;
        for (i = 2; i <= PIPE_STAGES - 1; i = i + 1)
            p_r[i] <= p_r[i-1];
    end

    assign p = p_r[PIPE_STAGES-1];

    // ------------------------------------------------------------------
    // Valid chain: one bit per stage
    // ------------------------------------------------------------------
    reg [PIPE_STAGES-1:0] v_r;

    always @(posedge clk) begin
        if (!rst_n) v_r <= {PIPE_STAGES{1'b0}};
        else        v_r <= {v_r[PIPE_STAGES-2:0], valid_in};
    end

    assign valid_out = v_r[PIPE_STAGES-1];

endmodule
