# shellcheck shell=sh
#
# summary: A pure-Python mix: recursion, a sieve, dicts, strings, objects and floats
#
# guest/aok/pybench.py. Unlike sympy, little of it is imports. The check is its result.

bench_time -o /tmp/pybench.out run python3 "$BENCH_DIR/guest/aok/pybench.py" 4
bench_check result "$(cat /tmp/pybench.out)"
