# shellcheck shell=sh
#
# Sourced by bench.py before each workload script, in the guest, under busybox sh.
#
# A workload reports by printing lines that start with @; anything else goes to its log:
#
#   @metric <name> <value> <unit>   a measurement; lower is better for every one in the suite
#   @check <name> <value>           a digest of the workload's output, which every correct build
#                                   must agree on
#   @info <name> <value...>         recorded but not compared, such as the runs a median came from
#   @fail <reason>                  the workload did not run as it should; its metrics are discarded
#
# Times come from /proc/uptime (10 ms resolution). Under TCG the guest's clock follows the host's,
# so they are host wall-clock times.
#
# BENCH_DIR is where bench.py copied the suite, and BENCH_LOG where commands' output goes.

# The guest's uptime in seconds, to two decimals.
bench_now() {
  cut -d ' ' -f 1 /proc/uptime
}

bench_metric() {
  echo "@metric $1 $2 $3"
}

bench_check() {
  echo "@check $1 $2"
}

bench_info() {
  _bench_name=$1
  shift
  echo "@info $_bench_name $*"
}

bench_fail() {
  echo "@fail $*"
  exit 1
}

# A digest of stdin, short enough to read in a table.
bench_digest() {
  md5sum | cut -c 1-12
}

# The seconds between two bench_now readings.
bench_elapsed() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'
}

# Runs a command once and reports its time in seconds; a failing command fails the workload. Output
# goes to BENCH_LOG, or with -o, stdout goes to that file, for the workload to digest.
#
#   bench_time [-o <file>] <metric> <command> [args...]
bench_time() {
  _bench_out=$BENCH_LOG
  if [ "$1" = -o ]; then
    _bench_out=$2
    shift 2
  fi
  _bench_metric=$1
  shift
  _bench_start=$(bench_now)
  "$@" >>"$_bench_out" 2>>"$BENCH_LOG" || bench_fail "$* exited with status $?"
  bench_metric "$_bench_metric" "$(bench_elapsed "$_bench_start" "$(bench_now)")" s
}

# Runs a command several times and reports the median, with every run as @info. For commands too
# short to time once, such as starting an interpreter.
#
#   bench_repeat <runs> <metric> <command> [args...]
bench_repeat() {
  _bench_runs=$1
  _bench_metric=$2
  shift 2
  _bench_times=
  _bench_i=0
  while [ "$_bench_i" -lt "$_bench_runs" ]; do
    _bench_start=$(bench_now)
    "$@" >>"$BENCH_LOG" 2>&1 || bench_fail "$* exited with status $?"
    _bench_times="$_bench_times $(bench_elapsed "$_bench_start" "$(bench_now)")"
    _bench_i=$((_bench_i + 1))
  done
  bench_info "${_bench_metric}_runs" "$_bench_times"
  # shellcheck disable=SC2086
  bench_metric "$_bench_metric" "$(printf '%s\n' $_bench_times | sort -n | awk '
    { v[NR] = $1 }
    END { printf "%.2f", NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')" s
}

# An empty scratch directory for a workload.
bench_scratch() {
  rm -rf "/tmp/bench-work/$1"
  mkdir -p "/tmp/bench-work/$1"
  echo "/tmp/bench-work/$1"
}
