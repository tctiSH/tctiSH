# shellcheck shell=sh
#
# summary: sha256sum over 8 MB, 30 times: integer rotates and adds in one hot loop
#
# busybox's sha256sum, which has no SHA instructions to use. The check is the digest.

bench_time -o /tmp/sha256.out hash sh -c 'for i in $(seq 30); do sha256sum /opt/bench/data.bin; done'
bench_check digest "$(sort -u /tmp/sha256.out | cut -d ' ' -f 1)"
