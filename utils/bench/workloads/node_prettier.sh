# shellcheck shell=sh
#
# summary: prettier formats 155 KB of JavaScript and TypeScript: a big JS program, V8 JIT-compiling
#
# The files ship with prettier. Loading prettier is about a third of the time. Much of the work
# runs before V8 has settled on what to optimize, and the code V8 writes is new guest code, which
# QEMU must translate and invalidate when V8 replaces it. The check is the formatted output.

cd /opt/prettier/node_modules/prettier || bench_fail "no prettier; prepare the disk again"
rm -f /tmp/prettier.out
bench_time -o /tmp/prettier.out format /opt/prettier/node_modules/.bin/prettier \
  doc.mjs index.d.ts standalone.mjs
bench_check output "$(bench_digest </tmp/prettier.out)"
