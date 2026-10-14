// ============================================================================
// tb_ref_mult.v - testbench self-test model (NOT one of the compared designs)
// ============================================================================
//
// Behavioral multiplier with the common MUL32-CMP interface and a latency of
// exactly PIPE_STAGES cycles (PIPE_STAGES = 0 gives a combinational path).
// Used only to prove that tb_mult32 passes a correct design and catches a
// broken one. FAULT selects a deliberate defect:
//
//   0  none
//   1  data error: flip p[37] when a[5] & b[7]
//   2  data error: unsigned product regardless of SIGNED_MODE
//   3  protocol: drop valid_out for every 1000th result
//   4  protocol: one extra cycle of latency when a[0] is set
//   5  protocol: one spurious valid_out pulse, the first time the pipeline
//      is empty after 500 accepted inputs
//   6  protocol: valid_out never asserted (testbench watchdog)
// ============================================================================

`timescale 1ns/1ps

module mult_tbref #(
    parameter SIGNED_MODE = 0,
    parameter PIPE_STAGES = 2,
    parameter FAULT       = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [63:0] p,
    output wire        valid_out
);

    wire signed [63:0] p_s = $signed(a) * $signed(b);
    wire        [63:0] p_u = a * b;

    reg [63:0] p_c;
    always @* begin
        p_c = (SIGNED_MODE != 0 && FAULT != 2) ? p_s : p_u;
        if (FAULT == 1 && a[5] && b[7]) p_c[37] = ~p_c[37];
    end

    integer n_acc;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)        n_acc <= 0;
        else if (valid_in) n_acc <= n_acc + 1;

    generate
        if (PIPE_STAGES == 0) begin : g_comb
            assign p         = p_c;
            assign valid_out = valid_in;
        end else begin : g_pipe
            reg [63:0] pd [0:PIPE_STAGES];
            reg        vd [0:PIPE_STAGES];
            reg        xd [0:PIPE_STAGES];     // "delay by one" tag (FAULT 4)
            integer    i;
            integer    n_out;
            reg        hold_v;
            reg [63:0] hold_p;
            wire       v_raw;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (i = 1; i <= PIPE_STAGES; i = i + 1) begin
                        vd[i] <= 1'b0;
                        xd[i] <= 1'b0;
                    end
                    n_out  <= 0;
                    hold_v <= 1'b0;
                end else begin
                    pd[1] <= p_c;
                    vd[1] <= valid_in;
                    xd[1] <= (FAULT == 4) && a[0];
                    for (i = 2; i <= PIPE_STAGES; i = i + 1) begin
                        pd[i] <= pd[i-1];
                        vd[i] <= vd[i-1];
                        xd[i] <= xd[i-1];
                    end
                    // FAULT 4: tagged results are held back one extra cycle.
                    hold_v <= vd[PIPE_STAGES] && xd[PIPE_STAGES];
                    hold_p <= pd[PIPE_STAGES];
                    if (v_raw) n_out <= n_out + 1;
                end
            end

            // FAULT 5: pipeline holds nothing and nothing enters this cycle.
            reg        any_v;
            reg        spur_done;
            always @* begin
                any_v = valid_in || hold_v;
                for (i = 1; i <= PIPE_STAGES; i = i + 1) any_v = any_v || vd[i];
            end
            wire spur = (FAULT == 5) && !spur_done && n_acc >= 500 && !any_v;
            always @(posedge clk or negedge rst_n)
                if (!rst_n)    spur_done <= 1'b0;
                else if (spur) spur_done <= 1'b1;

            wire v_last = vd[PIPE_STAGES] && !xd[PIPE_STAGES];
            assign v_raw = v_last || hold_v;
            assign p    = hold_v ? hold_p : pd[PIPE_STAGES];
            assign valid_out =
                (FAULT == 3) ? (v_raw && ((n_out % 1000) != 999)) :
                (FAULT == 5) ? (v_raw || spur) :
                (FAULT == 6) ? 1'b0 :
                v_raw;
        end
    endgenerate

endmodule
