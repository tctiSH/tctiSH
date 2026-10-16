# shellcheck shell=sh
#
# summary: Hot loops in Node.js: numbers, objects, strings and maps, in V8's optimized code
#
# guest/compute.js runs four small kernels that V8 optimizes early, so, unlike node_prettier, the
# time is mostly settled optimized code. The check is their checksum.

bench_time -o /tmp/compute.out run node "$BENCH_DIR/guest/compute.js" 2
bench_check checksum "$(cut -d ' ' -f 2 /tmp/compute.out)"
