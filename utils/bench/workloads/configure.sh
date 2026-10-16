# shellcheck shell=sh
#
# summary: GNU make's ./configure: hundreds of short processes, from sh and sed to gcc
#
# About two hundred autoconf checks, most of them a C compile. The time goes to starting processes,
# with their page faults and page table switches, and to gcc's startup, not to any one program.

dir=$(bench_scratch configure)
tar -xzf /opt/src/make.tar.gz -C "$dir" --strip-components 1 || bench_fail "no make source"
cd "$dir" || exit 1
bench_time run ./configure --disable-nls
bench_check config "$(bench_digest <src/config.h)"
