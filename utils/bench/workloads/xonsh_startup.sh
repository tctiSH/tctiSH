# shellcheck shell=sh
#
# summary: xonsh starts, runs nothing and exits: Python's startup and a few hundred module imports
#
# The median of three, after one that is not counted, which reads the files into the page cache.
# `xonsh -c exit` loads the shell and its configuration but not prompt_toolkit's interactive side;
# xonsh_keys times that.

xonsh -c exit >>"$BENCH_LOG" 2>&1 || bench_fail "xonsh would not start"
bench_repeat 3 start xonsh -c exit
