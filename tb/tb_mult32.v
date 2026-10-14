// ============================================================================
// tb_mult32.v - single self-checking testbench for all MUL32-CMP multipliers
// ============================================================================
//
// Compile-time configuration (defines, normally set from tb_cfg.vh which is
// included when TB_CFG_INC is defined - this avoids quoting problems with
// commas/parentheses on the Windows command line):
//
//   `DUT              module name of the device under test  (default mult_behav)
//   `SIGNED_MODE      0 = unsigned, 1 = signed               (default 0)
//   `PIPE_STAGES      passed to the DUT                      (default 2)
//   `DUT_EXTRA_PARAMS extra parameter overrides, e.g. .USE_BOOTH(1)
//
// Run-time plusargs:
//
//   +VECFILE=<path>   vector file from tb/golden.py           (required)
//   +MAXVEC=<n>       stop after n vectors (0 = whole file)   (default 0)
//   +WAIT             issue one vector, wait for its result, then issue the
//                     next (for non-pipelined DUTs such as shift-add).
//                     Without +WAIT vectors are streamed back-to-back.
//   +BUBBLE=<pct>     stream mode: probability (%) of an idle cycle before
//                     each vector, to exercise valid tracking  (default 10)
//   +LATENCY=<n>      expected latency in cycles; any vector whose result
//                     arrives with a different latency is an error
//   +SEED=<n>         seed for bubbles and idle-cycle garbage  (default 1)
//   +TIMEOUT=<n>      abort if an input has no result after n cycles
//                     (default 10000)
//
// Checking:
//   * Every accepted input (valid_in high at a rising edge) is pushed into an
//     in-order scoreboard together with the expected product and the cycle
//     number. Every valid_out pops one entry and compares p with !== , so X/Z
//     on p is a mismatch.
//   * valid_out with an empty scoreboard, an input without a result after
//     +TIMEOUT cycles, X on valid_out, a latency that
//     differs from +LATENCY (or that is not constant when +LATENCY is not
//     given), and results still missing at the end are all errors.
//   * While valid_in is low, a and b carry random garbage, so a DUT that
//     ignores valid_in shows up as a mismatch.
//
// The final line is "RESULT: PASS" or "RESULT: FAIL" for scripts to grep.
// ============================================================================

`timescale 1ns/1ps

`ifdef TB_CFG_INC
 `include "tb_cfg.vh"
`endif

`ifndef DUT
 `define DUT mult_behav
`endif
`ifndef SIGNED_MODE
 `define SIGNED_MODE 0
`endif
`ifndef PIPE_STAGES
 `define PIPE_STAGES 2
`endif

module tb_mult32;

    localparam integer SB_DEPTH = 4096;    // must exceed the deepest pipeline
    localparam integer MAX_SHOW = 10;      // mismatches printed in detail

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    reg         clk      = 1'b0;
    reg         rst_n    = 1'b0;
    reg         valid_in = 1'b0;
    reg  [31:0] a        = 32'd0;
    reg  [31:0] b        = 32'd0;
    reg  [63:0] exp_in   = 64'd0;          // expected product, travels with a/b
    wire [63:0] p;
    wire        valid_out;

    `DUT #(
        .SIGNED_MODE (`SIGNED_MODE),
        .PIPE_STAGES (`PIPE_STAGES)
`ifdef DUT_EXTRA_PARAMS
        , `DUT_EXTRA_PARAMS
`endif
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (a),
        .b         (b),
        .p         (p),
        .valid_out (valid_out)
    );

    always #5 clk = ~clk;                  // 100 MHz, the value is irrelevant

`ifdef DUMP_VCD
    // ------------------------------------------------------------------
    // Optional VCD of the top-level ports only (compile with DUMP_VCD,
    // e.g. xvlog -d DUMP_VCD). Written to dump.vcd in the run directory.
    // +DUMPCYCLES=<n> stops dumping after n clock cycles (default: whole run).
    // ------------------------------------------------------------------
    integer dump_cycles;
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(1, clk, rst_n, valid_in, valid_out, a, b, p);
        if ($value$plusargs("DUMPCYCLES=%d", dump_cycles)) begin
            repeat (dump_cycles) @(posedge clk);
            $dumpoff;
        end
    end
`endif

    // ------------------------------------------------------------------
    // Run-time options
    // ------------------------------------------------------------------
    reg [8*1024-1:0] vecfile;
    integer maxvec, bubble_pct, exp_lat, seed, timeout;
    reg     wait_mode, lat_given;

    // ------------------------------------------------------------------
    // Scoreboard and statistics (written by the monitor only)
    // ------------------------------------------------------------------
    reg [31:0] sb_a [0:SB_DEPTH-1];
    reg [31:0] sb_b [0:SB_DEPTH-1];
    reg [63:0] sb_p [0:SB_DEPTH-1];
    integer    sb_t [0:SB_DEPTH-1];

    integer cycle      = 0;
    integer n_pushed   = 0;                // accepted inputs
    integer n_checked  = 0;                // results compared
    integer n_mismatch = 0;
    integer n_proto    = 0;                // protocol / latency errors
    integer lat_min    = 0;
    integer lat_max    = 0;
    integer lat_ref    = -1;

    integer idx, lat;

    always @(posedge clk) begin
        cycle = cycle + 1;

        if (rst_n) begin
            if (valid_out === 1'bx || valid_out === 1'bz) begin
                n_proto = n_proto + 1;
                $display("[%0d] ERROR: valid_out is %b", cycle, valid_out);
            end

            // Push before pop so that a zero-latency DUT also works.
            if (valid_in) begin
                if (n_pushed - n_checked >= SB_DEPTH) begin
                    $display("[%0d] FATAL: scoreboard overflow (%0d outstanding)",
                             cycle, n_pushed - n_checked);
                    summary;
                    $finish;
                end
                idx       = n_pushed % SB_DEPTH;
                sb_a[idx] = a;
                sb_b[idx] = b;
                sb_p[idx] = exp_in;
                sb_t[idx] = cycle;
                n_pushed  = n_pushed + 1;
            end

            if (valid_out === 1'b1) begin
                if (n_checked == n_pushed) begin
                    n_proto = n_proto + 1;
                    $display("[%0d] ERROR: valid_out with no outstanding input", cycle);
                end else begin
                    idx = n_checked % SB_DEPTH;
                    lat = cycle - sb_t[idx];

                    if (p !== sb_p[idx]) begin
                        n_mismatch = n_mismatch + 1;
                        if (n_mismatch <= MAX_SHOW)
                            $display("[%0d] MISMATCH #%0d: a=%h b=%h  got p=%h  exp p=%h  (xor %h)",
                                     cycle, n_checked, sb_a[idx], sb_b[idx], p, sb_p[idx],
                                     p ^ sb_p[idx]);
                    end

                    if (n_checked == 0) begin
                        lat_min = lat;
                        lat_max = lat;
                    end else begin
                        if (lat < lat_min) lat_min = lat;
                        if (lat > lat_max) lat_max = lat;
                    end

                    if (lat_given) begin
                        if (lat != exp_lat) begin
                            n_proto = n_proto + 1;
                            if (n_proto <= MAX_SHOW)
                                $display("[%0d] ERROR: vector #%0d latency %0d, expected %0d",
                                         cycle, n_checked, lat, exp_lat);
                        end
                    end else if (lat_ref < 0) begin
                        lat_ref = lat;
                    end else if (lat != lat_ref) begin
                        n_proto = n_proto + 1;
                        if (n_proto <= MAX_SHOW)
                            $display("[%0d] ERROR: vector #%0d latency %0d, first vector had %0d",
                                     cycle, n_checked, lat, lat_ref);
                    end

                    n_checked = n_checked + 1;
                end
            end

            // Watchdog: the oldest outstanding input must not wait forever.
            if (n_pushed > n_checked &&
                cycle - sb_t[n_checked % SB_DEPTH] > timeout) begin
                $display("[%0d] FATAL: no result for input #%0d after %0d cycles",
                         cycle, n_checked, timeout);
                summary;
                $finish;
            end
        end
    end

    // ------------------------------------------------------------------
    // Driver
    // ------------------------------------------------------------------
    integer fd, r, n_issued, n_lines;
    reg [31:0] va, vb;
    reg [63:0] vp;
    reg        done;

    // One cycle with valid_in low and garbage on the operands.
    task drive_idle;
        begin
            @(posedge clk);
            valid_in <= 1'b0;
            a        <= $random(seed);
            b        <= $random(seed);
            exp_in   <= 64'd0;
        end
    endtask

    task summary;
        begin
            $display("============================================================");
            $display(" tb_mult32 summary");
            $display("   vector file   : %0s", vecfile);
            $display("   SIGNED_MODE   : %0d   PIPE_STAGES: %0d", `SIGNED_MODE, `PIPE_STAGES);
            $display("   issue mode    : %0s", wait_mode ? "wait (one at a time)" : "stream");
            $display("   vectors read  : %0d", n_lines);
            $display("   inputs taken  : %0d", n_pushed);
            $display("   results       : %0d", n_checked);
            $display("   latency       : min %0d  max %0d cycles", lat_min, lat_max);
            $display("   mismatches    : %0d", n_mismatch);
            $display("   protocol errs : %0d", n_proto);
            $display("   sim cycles    : %0d", cycle);
            if (n_mismatch == 0 && n_proto == 0 && n_checked == n_pushed &&
                n_pushed == n_lines && n_lines > 0)
                $display("RESULT: PASS");
            else
                $display("RESULT: FAIL");
            $display("============================================================");
        end
    endtask

    initial begin
        if (!$value$plusargs("VECFILE=%s", vecfile)) begin
            $display("FATAL: +VECFILE=<path> is required");
            $display("RESULT: FAIL");
            $finish;
        end
        if (!$value$plusargs("MAXVEC=%d",  maxvec))     maxvec     = 0;
        if (!$value$plusargs("BUBBLE=%d",  bubble_pct)) bubble_pct = 10;
        if (!$value$plusargs("SEED=%d",    seed))       seed       = 1;
        if (!$value$plusargs("TIMEOUT=%d", timeout))    timeout    = 10000;
        lat_given = $value$plusargs("LATENCY=%d", exp_lat);
        wait_mode = $test$plusargs("WAIT");

        fd = $fopen(vecfile, "r");
        if (fd == 0) begin
            $display("FATAL: cannot open vector file %0s", vecfile);
            $display("RESULT: FAIL");
            $finish;
        end

        n_issued = 0;
        n_lines  = 0;
        done     = 1'b0;

        // Reset
        repeat (5) drive_idle;
        @(posedge clk) rst_n <= 1'b1;
        repeat (2) drive_idle;

        while (!done) begin
            r = $fscanf(fd, "%h %h %h\n", va, vb, vp);
            if (r != 3) begin
                if (!$feof(fd)) begin
                    $display("FATAL: parse error in %0s after %0d vectors", vecfile, n_lines);
                    n_proto = n_proto + 1;
                end
                done = 1'b1;
            end else begin
                n_lines = n_lines + 1;

                if (wait_mode) begin
                    // Previous result must be back before the next issue.
                    while (n_checked < n_issued) begin
                        drive_idle;
                    end
                end else begin
                    while (bubble_pct > 0 &&
                           (($random(seed) & 32'h7fffffff) % 100) < bubble_pct)
                        drive_idle;
                end

                @(posedge clk);
                valid_in <= 1'b1;
                a        <= va;
                b        <= vb;
                exp_in   <= vp;
                n_issued = n_issued + 1;

                if (maxvec > 0 && n_lines >= maxvec) done = 1'b1;
                if (n_lines % 100000 == 0)
                    $display("[%0d] progress: %0d vectors issued, %0d mismatches",
                             cycle, n_lines, n_mismatch);
            end
        end
        $fclose(fd);

        // Drain
        drive_idle;
        // Wait on n_issued (driver-owned): n_pushed is updated by the monitor
        // on the same clock edge and may not have caught up yet.
        while (n_checked < n_issued) begin
            drive_idle;
        end
        repeat (5) drive_idle;             // catch spurious late valid_out

        summary;
        $finish;
    end

endmodule
