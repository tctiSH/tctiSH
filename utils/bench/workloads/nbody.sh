# shellcheck shell=sh
#
# summary: n-body, 20 million steps: a tight double-precision loop with sqrt
#
# guest/aok/nbody.c, built at -O2 when the disk is made. The check is the energy it prints before
# and after.

bench_time -o /tmp/nbody.out run /opt/bench/bin/nbody 20000000
bench_check energy "$(bench_digest </tmp/nbody.out)"
