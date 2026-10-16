# Benchmarks

Real programs, timed in the guest on our QEMU fork built for this Mac. Use it to judge emulator
changes for performance and correctness.

```sh
make bench-disk                                   # once: build the benchmark disk
make bench BACKEND=tcti ROUNDS=3                  # all workloads, three rounds
make bench BACKEND=jit WORKLOADS="xonsh_keys"     # one workload
make bench-baseline COMMIT=3c64b6a7a8 NAME=base   # build a commit to compare against
make bench-compare LABELS="tcti-base tcti-change" # compare results
make bench-list                                   # list the workloads
python3 utils/bench/bench.py run --help           # all options; pass them with ARGS=
```

Each workload boots the app's guest and machine on `build-macOS-arm64/qemu_hybrid` (or
`BENCH_QEMU=`), on a fresh copy of the disk. One boot per workload, because a shared boot slowed
later workloads by up to 4x. It does not measure device speed, iOS-only code paths, or disk and
network I/O.

## Workloads

| Workload         | Runs                                 | Exercises                          |
| ---------------- | ------------------------------------ | ---------------------------------- |
| `blender_render` | A small Cycles render                | Float and AVX2 SIMD, threaded      |
| `sympy`          | Integrate, differentiate, solve      | A large Python program             |
| `lean_plausible` | Lean 4 builds a library              | Short compiler processes, threaded |
| `xonsh_startup`  | `xonsh -c exit`                      | CPython startup and imports        |
| `xonsh_keys`     | Typing a line into xonsh, key by key | CPython's interpreter; typing lag  |
| `lua_build`      | gcc builds Lua at `-O2`              | A large amount of guest code       |
| `configure`      | GNU make's `./configure`             | fork, exec, page faults            |
| `node_startup`   | `node -e 0`                          | V8 and Node startup                |
| `node_prettier`  | prettier formats 155 KB of JS and TS | Fresh guest JIT code               |
| `node_compute`   | Hot JS loops                         | Settled guest JIT code             |

Every metric is a time; lower is better. A round took 5 minutes on the JIT and 23 on TCTI (M2 Max,
busy).

## Comparing Builds

Results are stored per label in `build-bench/results/`. The default label is the backend and fork
commit, such as `tcti-3c64b6a7a8`. Running a label again adds rounds; a label refuses results from a
different QEMU, guest or disk (`ARGS=--replace` starts it over).

```sh
make bench-baseline COMMIT=3c64b6a7a8 NAME=base
make bench BACKEND=tcti LABEL=tcti-base BENCH_QEMU=build-macOS-arm64/qemu_hybrid-base/qemu-system-x86_64
make bench BACKEND=tcti LABEL=tcti-change
make bench-compare LABELS="tcti-base tcti-change"
```

`bench-compare` shows each metric's median, spread (±) and ratio to the first label (`0.92x` is 8%
faster), and flags any output that differs between builds.

For reliable times: use a quiet Mac (`ARGS="--wait-quiet 1.5"`), alternate builds round by round,
and ignore differences within the spread. If only TCTI moves unexpectedly, check that gadgets start
at the same address in both builds (`nm -n <binary> | grep -m1 _gadget_`).

## The Disk

`guest/prepare.sh` installs the programs: Blender, sympy, gcc, Node.js and xonsh from Alpine edge,
and pinned versions of Lean, Lua, GNU make and prettier. Alpine packages can't be pinned, so the
disk is kept, and every result records which disk it used. To make a new one, run
`make clean-bench bench-disk`, which also deletes all results.

## Adding a Workload

Add `workloads/<name>.sh`, starting with a `# summary:` line. It runs in the guest after
`guest/lib.sh`, which documents how to report results and provides `bench_time` and `bench_repeat`.
Time only the work, report a `@check` of the output, and install nothing: add dependencies to
`guest/prepare.sh` and rebuild the disk. Helper files go in `guest/`, which the guest sees as
`$BENCH_DIR/guest/`.

`gx.py` runs commands in the guest over hvc0, and can be used directly:
`utils/bench/gx.py <socket> 'uname -a'`.
