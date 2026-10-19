# shellcheck shell=sh
#
# summary: xz -3 compresses 8 MB of text on one thread: LZMA's match finder and range coder
#
# The text is guest/aok/gen_data.py's, made with the disk. The check is the compressed file.

bench_time -o /tmp/xz.out compress xz -T1 -3 -c /opt/bench/data.bin
bench_check output "$(bench_digest </tmp/xz.out)"
