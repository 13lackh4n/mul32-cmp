# ----------------------------------------------------------------------------
# synth_util.tcl - out-of-context synthesis of one module, utilization only.
#
#   vivado -mode batch -source scripts/synth_util.tcl \
#          -tclargs <top> <rtl file> <util report> [GENERIC VALUE ...]
#
# Generics are given as separate name/value words because vivado.bat on
# Windows splits command-line arguments at '='.
#
# Out-of-context mode: no I/O buffers are inserted, so the report counts
# only the multiplier itself. Timing / fmax is Step 7 (scripts/synth.tcl).
# ----------------------------------------------------------------------------

set PART xc7a100tcsg324-1

if {[llength $argv] < 3} {
    puts "usage: -tclargs <top> <rtl file> <util report> \[GENERIC VALUE ...\]"
    exit 1
}
set top      [lindex $argv 0]
set rtl      [lindex $argv 1]
set rpt      [lindex $argv 2]
set generics [lrange $argv 3 end]

read_verilog $rtl

set gen_args {}
foreach {name value} $generics { lappend gen_args -generic "$name=$value" }

synth_design -top $top -part $PART -mode out_of_context {*}$gen_args

file mkdir [file dirname $rpt]
report_utilization -file $rpt
puts "synth_util.tcl: wrote $rpt"
