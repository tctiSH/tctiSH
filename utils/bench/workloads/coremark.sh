# shellcheck shell=sh
#
# summary: CoreMark, 30000 iterations: small integer kernels (lists, matrices, a state machine)
#
# EEMBC's CoreMark, built at -O2 when the disk is made. The check is its final CRC.

bench_time -o /tmp/coremark.out run /opt/bench/bin/coremark 0x0 0x0 0x66 30000 7 1 2000
# CoreMark counts any run under 10 s as an error, and JIT runs can be shorter, so check its three
# algorithms' CRCs against the ones core_main.c expects of this run instead.
for crc in "crclist *: 0xe714" "crcmatrix *: 0x1fd7" "crcstate *: 0x8e3a"; do
  grep -q "$crc" /tmp/coremark.out || bench_fail "CoreMark's ${crc%% *} is wrong"
done
bench_check crc "$(sed -n 's/.*crcfinal *: *//p' /tmp/coremark.out)"
