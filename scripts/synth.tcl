# ----------------------------------------------------------------------------
# synth.tcl - synthesis + implementation + fmax search for one module.
#
#   vivado -mode batch -source scripts/synth.tcl \
#          -tclargs <name> <top> <rtl file> [GENERIC VALUE ...]
#
#   <name>  report prefix, e.g. mult_wallace_b1
#   Generics are separate name/value words (vivado.bat splits at '=').
#
# Flow per clock period (identical for every module; Vivado defaults):
#   synth_design -mode out_of_context
#   opt_design ; place_design ; phys_opt_design ; route_design
#
# A period PASSES when, after routing, setup (WNS), hold (WHS) and pulse
# width (WPWS) slack are all >= 0.
#
# fmax search:
#   1. coarse: start at 5.000 ns. If it passes, tighten in 0.5 ns steps until
#      a period fails; the last passing period is the coarse result
#      ("back off 0.5 ns"). If 5.000 ns fails, loosen in 0.5 ns steps until
#      one passes.
#   2. refine: bisect between the last pass and the first fail until they
#      are <= 0.05 ns apart. The final passing period is the achieved fmax.
#
# Output (reports/):
#   <name>_synth.rpt   post-synthesis utilization          (final period)
#   <name>_impl.rpt    route status + DRC                  (final period)
#   <name>_timing.rpt  report_timing_summary, post-route   (final period)
#   <name>_util.rpt    post-route utilization              (final period)
#   <name>_power.rpt   report_power, vectorless defaults   (final period)
#   <name>_fmax_search.txt  every search point: period, WNS, WHS, WPWS
# Every search point's reports are kept in build/impl/<name>/T<period>/.
# ----------------------------------------------------------------------------

set PART      xc7a100tcsg324-1
set T_START   5.000
set T_STEP    0.500
set T_RESOL   0.050
set T_MIN     0.500
set T_MAX     50.000

if {[llength $argv] < 3} {
    puts "usage: -tclargs <name> <top> <rtl file> \[GENERIC VALUE ...\]"
    exit 1
}
set name     [lindex $argv 0]
set top      [lindex $argv 1]
set rtl      [file normalize [lindex $argv 2]]
set generics [lrange $argv 3 end]

set root     [file normalize [file join [file dirname [info script]] ..]]
set xdc_src  [file join $root constr timing.xdc]
set rpt_dir  [file join $root reports]
set work     [file join $root build impl $name]
file mkdir $work $rpt_dir

set gen_args {}
foreach {gname gvalue} $generics { lappend gen_args -generic "$gname=$gvalue" }

# Copy of timing.xdc with only the clock period replaced.
proc make_xdc {src dst period} {
    set fh [open $src r]; set txt [read $fh]; close $fh
    set n [regsub -all {(create_clock\s+-name\s+clk\s+-period\s+)[0-9.]+} $txt \
               "\\1[format %.3f $period]" txt]
    if {$n != 1} { error "make_xdc: expected exactly one create_clock -period in $src" }
    set fh [open $dst w]; puts -nonewline $fh $txt; close $fh
}

# Parse WNS, WHS, WPWS from the "Design Timing Summary" table.
proc timing_summary_slacks {txt} {
    set lines [split $txt "\n"]
    for {set i 0} {$i < [llength $lines]} {incr i} {
        if {[regexp {^\s*WNS\(ns\)\s+TNS\(ns\)} [lindex $lines $i]]} {
            set vals [regexp -all -inline {\S+} [lindex $lines [expr {$i + 2}]]]
            # WNS TNS fail total WHS THS fail total WPWS TPWS fail total
            return [list [lindex $vals 0] [lindex $vals 4] [lindex $vals 8]]
        }
    }
    error "timing_summary_slacks: Design Timing Summary not found"
}

array set RESULT {}
set search_log {}

proc run_point {period} {
    global PART top rtl gen_args xdc_src work RESULT search_log
    set key [format %.3f $period]
    if {[info exists RESULT($key)]} { return $RESULT($key) }

    set dir [file join $work "T$key"]
    file mkdir $dir
    make_xdc $xdc_src [file join $dir timing.xdc] $period

    close_project -quiet
    create_project -in_memory -part $PART
    read_verilog $rtl
    read_xdc [file join $dir timing.xdc]

    synth_design -top $top -part $PART -mode out_of_context {*}$gen_args
    report_utilization -file [file join $dir synth.rpt]

    opt_design
    place_design
    phys_opt_design
    route_design

    set ts [report_timing_summary -max_paths 10 -report_unconstrained -return_string]
    set fh [open [file join $dir timing.rpt] w]; puts $fh $ts; close $fh
    report_utilization  -file [file join $dir util.rpt]
    report_route_status -file [file join $dir impl.rpt]
    report_drc          -file [file join $dir drc.rpt]
    report_power        -file [file join $dir power.rpt]

    lassign [timing_summary_slacks $ts] wns whs wpws
    set pass [expr {$wns >= 0 && $whs >= 0 && $wpws >= 0}]
    set RESULT($key) $pass
    set line [format "%8s ns  %8.2f MHz  WNS %8s  WHS %8s  WPWS %8s  %s" \
                  $key [expr {1000.0 / $period}] $wns $whs $wpws \
                  [expr {$pass ? "PASS" : "FAIL"}]]
    lappend search_log $line
    puts "FMAX-SEARCH $line"
    return $pass
}

# Debug: FMAX_SINGLE=<period> runs that one point only (no reports/ output).
if {[info exists ::env(FMAX_SINGLE)]} {
    run_point $::env(FMAX_SINGLE)
    foreach l $search_log { puts "FMAX-SINGLE $l" }
    return
}

# ---- 1. coarse search ------------------------------------------------------
set t $T_START
if {[run_point $t]} {
    set t_pass $t
    while {1} {
        set t [expr {$t - $T_STEP}]
        if {$t < $T_MIN} { set t_fail {}; break }
        if {[run_point $t]} { set t_pass $t } else { set t_fail $t; break }
    }
} else {
    set t_fail $t
    while {1} {
        set t [expr {$t + $T_STEP}]
        if {$t > $T_MAX} { error "no passing period up to $T_MAX ns" }
        if {[run_point $t]} { set t_pass $t; break } else { set t_fail $t }
    }
}
set t_coarse $t_pass

# ---- 2. bisection refine ---------------------------------------------------
if {$t_fail ne {}} {
    while {$t_pass - $t_fail > $T_RESOL + 1e-9} {
        set mid [expr {round(($t_pass + $t_fail) / 2.0 * 1000.0) / 1000.0}]
        if {[run_point $mid]} { set t_pass $mid } else { set t_fail $mid }
    }
}

# ---- reports for the final period ------------------------------------------
set key [format %.3f $t_pass]
set dir [file join $work "T$key"]
file copy -force [file join $dir synth.rpt]  [file join $rpt_dir "${name}_synth.rpt"]
file copy -force [file join $dir timing.rpt] [file join $rpt_dir "${name}_timing.rpt"]
file copy -force [file join $dir util.rpt]   [file join $rpt_dir "${name}_util.rpt"]
file copy -force [file join $dir power.rpt]  [file join $rpt_dir "${name}_power.rpt"]
set fh [open [file join $rpt_dir "${name}_impl.rpt"] w]
foreach f {impl.rpt drc.rpt} {
    set in [open [file join $dir $f] r]; puts $fh [read $in]; close $in
}
close $fh

set fh [open [file join $rpt_dir "${name}_fmax_search.txt"] w]
puts $fh "fmax search for $name  (top $top, generics: $generics, part $PART)"
puts $fh "flow: synth_design -mode out_of_context; opt_design; place_design; phys_opt_design; route_design"
puts $fh "pass = post-route WNS >= 0 && WHS >= 0 && WPWS >= 0"
puts $fh ""
foreach l $search_log { puts $fh $l }
puts $fh ""
puts $fh [format "coarse (0.5 ns steps) : %.3f ns = %.2f MHz" $t_coarse [expr {1000.0 / $t_coarse}]]
puts $fh [format "achieved (bisected)   : %.3f ns = %.2f MHz" $t_pass   [expr {1000.0 / $t_pass}]]
if {$t_fail ne {}} {
    puts $fh [format "first failing period  : %.3f ns" $t_fail]
}
close $fh
puts "FMAX-RESULT $name coarse [format %.3f $t_coarse] ns, achieved [format %.3f $t_pass] ns ([format %.2f [expr {1000.0 / $t_pass}]] MHz)"
