# ----------------------------------------------------------------------------
# timing.xdc - the single constraint file used for every module.
#
# The clock period below is a placeholder: scripts/synth.tcl rewrites the
# -period value for each point of the fmax search and changes nothing else.
#
# Inputs and outputs get a 0 ns external delay so that port-to-register and
# register-to-port logic is timed too (the out-of-context netlist has no I/O
# buffers). This matters for designs with logic before their first register
# (mult_shiftadd loads |a|, |b| straight from the ports); for the others the
# port paths are a direct register connection and never critical.
# ----------------------------------------------------------------------------

create_clock -name clk -period 5.000 [get_ports clk]

set_input_delay  -clock clk 0.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk 0.000 [get_ports -filter {DIRECTION == OUT}]

# Hold at the module boundary depends on the (absent) surrounding design:
# with a 0 ns input delay, data at an unbuffered OOC port always arrives
# before the clock insertion delay and would show fake hold violations.
# Port paths are therefore checked for setup only; all internal
# register-to-register paths keep their hold checks.
set_false_path -hold -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -hold -to   [get_ports -filter {DIRECTION == OUT}]
