# shellcheck shell=sh
#
# summary: busybox awk counts the words of 8 MB of text: an interpreter, hashing and strings
#
# The check is the total.

bench_time -o /tmp/awk.out count awk '{ for (i = 1; i <= NF; i++) c[$i]++ }
  END { n = 0; for (w in c) n += c[w] * length(w); print n }' /opt/bench/data.bin
bench_check total "$(cat /tmp/awk.out)"
