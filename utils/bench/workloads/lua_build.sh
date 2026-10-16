# shellcheck shell=sh
#
# summary: gcc builds Lua 5.4 at -O2, on every vCPU: a C compiler's large, branchy code
#
# About thirty C files, mostly cc1's time. cc1 has far more code than any other workload, so this
# tests coping with a lot of guest code rather than running one loop fast. The check is the built
# interpreter and what it computes.

dir=$(bench_scratch lua)
tar -xzf /opt/src/lua.tar.gz -C "$dir" --strip-components 1 || bench_fail "no Lua source"
cd "$dir" || exit 1
bench_time build make -j "$(nproc)" linux
bench_check binary "$(cat src/lua src/luac | bench_digest)"
bench_check runs "$(src/lua -e 'local s = 0
  for i = 1, 100000 do s = (s * 31 + i) % 1000003 end
  print(s)')"
