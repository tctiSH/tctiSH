# shellcheck shell=sh
#
# summary: Cycles renders a small scene on the CPU: float and AVX2 code, threaded
#
# The scene is guest/scene.py. `render` is Cycles' render time, and `total` the whole Blender
# process, startup included.

rm -f /tmp/render.png
start=$(bench_now)
blender -b --factory-startup --python "$BENCH_DIR/guest/scene.py" >/tmp/blender.out 2>&1 ||
  bench_fail "blender exited with status $?"
bench_metric total "$(bench_elapsed "$start" "$(bench_now)")" s
cat /tmp/blender.out >>"$BENCH_LOG"
grep '^@' /tmp/blender.out
