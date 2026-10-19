# shellcheck shell=sh
#
# summary: Node.js again after the page cache is dropped: QEMU invalidating code in reused memory
#
# A long-running guest keeps reusing memory that held code, as the page cache turns over and V8
# frees what it compiled. Every write to such memory invalidates QEMU's translations of it. This
# runs guest/compute.js three times untimed, as the cost grows with how much memory has held code,
# drops the page cache, and times one more run. Compare with node_compute, the same run in a fresh
# guest.

for _ in 1 2 3; do
  node "$BENCH_DIR/guest/compute.js" 1 >>"$BENCH_LOG" 2>&1 || bench_fail "node would not run"
done
sync
echo 3 >/proc/sys/vm/drop_caches
bench_time -o /tmp/compute.out rerun node "$BENCH_DIR/guest/compute.js" 2
bench_check checksum "$(cut -d ' ' -f 2 /tmp/compute.out)"
