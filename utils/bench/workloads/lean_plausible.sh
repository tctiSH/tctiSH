# shellcheck shell=sh
#
# summary: Lean 4 builds the plausible library from clean: many short compiler processes, threaded
#
# lake runs a Lean process per module, on every vCPU it sees, so this is also the suite's
# multi-threaded build. The check digests the .olean files the build produces, not its log, which
# carries timings.

cd /opt/plausible || bench_fail "no /opt/plausible; prepare the disk again"
rm -rf .lake/build
bench_time build lake build
bench_check oleans "$(find .lake/build -name '*.olean' | sort | xargs cat | bench_digest)"
bench_info oleans "$(find .lake/build -name '*.olean' | wc -l) files"
