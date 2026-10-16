# shellcheck shell=sh
#
# summary: Node.js starts and exits: V8's startup snapshot, its isolate and Node's bootstrap
#
# The median of five, after one that is not counted, which reads the files into the page cache.

node -e 0 >>"$BENCH_LOG" 2>&1 || bench_fail "node would not start"
bench_repeat 5 start node -e 0
