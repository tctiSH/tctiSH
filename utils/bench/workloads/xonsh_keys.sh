# shellcheck shell=sh
#
# summary: Typing into xonsh's prompt, a key at a time: the latency you feel at the keyboard
#
# guest/keys.py runs xonsh on a pty and types a 57-key line, timing each key's response: handling
# the key, highlighting the line and redrawing. `prompt` is the time to the first prompt. An untimed
# start first warms the page cache.

xonsh -c exit >>"$BENCH_LOG" 2>&1 || bench_fail "xonsh would not start"
python3 "$BENCH_DIR/guest/keys.py" 'ls -la /usr/lib | grep python && echo done with this line' \
  -- xonsh 2>>"$BENCH_LOG"
