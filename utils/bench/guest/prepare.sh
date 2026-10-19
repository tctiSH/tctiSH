# shellcheck shell=sh
#
# Installs the workloads' programs onto a guest booted from assets/empty.qcow, which becomes
# build-bench/bench.qcow. `bench.py prepare` runs it on the JIT, as it installs a few gigabytes.
#
# Lean, plausible, Lua, GNU make, prettier and CoreMark are pinned by version, and checked against
# the digests below where they are files. Alpine's packages (Python, sympy, Blender, Node.js, gcc,
# xonsh, xz) can't be pinned: the guest tracks edge, which drops old versions within weeks. So the
# disk is kept, the manifest written at the end lists every version, and bench.py records its
# digest with each result.

set -eu

LEAN_VERSION=4.22.0
LEAN_SHA256=85097a4d659fe388193a5efb0c413b880e101f1290cc41d00eb60847b18f064e
# plausible depends on nothing but core Lean, and its lean-toolchain at this tag names the release
# above. The commit, rather than the tag, as a tag can be moved.
PLAUSIBLE_COMMIT=b100ad4c5d74a464f497aaa8e7c74d86bf39a56f
LUA_VERSION=5.4.8
LUA_SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
MAKE_VERSION=4.4.1
MAKE_SHA256=dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3
# Has no dependencies, so this one version is all npm installs.
PRETTIER_VERSION=3.6.2
# main as of 2025-05: the last release, v1.01, predates the posix port built with below.
COREMARK_COMMIT=1f483d5b8316753a742cbf5590caf5bd0a4e4777

# Blender's remote-asset code imports cattrs and requests, which Alpine's package does not depend
# on; without them it fails at startup. gcompat runs Lean's glibc binaries on musl.
PACKAGES="bash curl git tar zstd gcompat python3 py3-sympy blender py3-cattrs py3-requests
  gcc make musl-dev nodejs npm xz"
# xonsh is in edge's testing repository rather than community.
TESTING_PACKAGES="xonsh"
TESTING=https://dl-cdn.alpinelinux.org/alpine/edge/testing

step() {
  echo "==> $*"
}

# Runs a command quietly, showing its last line, or all of its output if it fails. A pipe into tail
# would do the first, but hide the failure.
quietly() {
  "$@" >/tmp/prepare-step.out 2>&1 || {
    cat /tmp/prepare-step.out
    echo "failed: $*" >&2
    exit 1
  }
  tail -1 /tmp/prepare-step.out
}

fetch() {
  # fetch <url> <file> <sha256>
  curl -fsSL --retry 3 -o "$2" "$1"
  echo "$3  $2" | sha256sum -c -s || {
    echo "$2 from $1 does not match its pinned digest" >&2
    exit 1
  }
}

# Guest DNS goes through slirp to the host's resolver, and has been seen to fail transiently; an
# index that did not load leaves half the packages missing, so try again rather than carry on.
step "updating the package indexes"
tries=0
until apk update >/tmp/apk-update.out 2>&1 &&
  ! grep -qE '[1-9][0-9]* unavailable' /tmp/apk-update.out; do
  tries=$((tries + 1))
  [ "$tries" -lt 6 ] || {
    cat /tmp/apk-update.out
    exit 1
  }
  sleep 5
done
tail -1 /tmp/apk-update.out

step "installing packages"
# shellcheck disable=SC2086
quietly apk add --no-progress $PACKAGES
# shellcheck disable=SC2086
quietly apk add --no-progress --repository "$TESTING" $TESTING_PACKAGES

mkdir -p /opt/src

step "Lean $LEAN_VERSION"
LEAN_RELEASES=https://github.com/leanprover/lean4/releases/download
fetch "$LEAN_RELEASES/v$LEAN_VERSION/lean-$LEAN_VERSION-linux.tar.zst" \
  /tmp/lean.tar.zst "$LEAN_SHA256"
rm -rf "/opt/lean-$LEAN_VERSION-linux"
tar --zstd -xf /tmp/lean.tar.zst -C /opt
rm /tmp/lean.tar.zst
ln -sfn "/opt/lean-$LEAN_VERSION-linux" /opt/lean
# Under gcompat, Lean finds its prefix from the running executable, which is musl's loader, so it
# believes it is installed at /. Make that true.
ln -sfn /opt/lean/bin/lean /bin/lean
ln -sfn /opt/lean/bin/lake /bin/lake
ln -sfn /opt/lean/lib/lean /lib/lean
mkdir -p /include
ln -sfn /opt/lean/include/lean /include/lean

step "plausible at $PLAUSIBLE_COMMIT"
rm -rf /opt/plausible
git clone -q https://github.com/leanprover-community/plausible /opt/plausible
git -C /opt/plausible checkout -q "$PLAUSIBLE_COMMIT"
echo "its toolchain: $(cat /opt/plausible/lean-toolchain)"

step "Lua $LUA_VERSION and GNU make $MAKE_VERSION"
fetch "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" /opt/src/lua.tar.gz "$LUA_SHA256"
fetch "https://ftp.gnu.org/gnu/make/make-$MAKE_VERSION.tar.gz" /opt/src/make.tar.gz "$MAKE_SHA256"

step "prettier $PRETTIER_VERSION"
rm -rf /opt/prettier
mkdir -p /opt/prettier
(cd /opt/prettier &&
  quietly npm install --no-audit --no-fund --no-update-notifier "prettier@$PRETTIER_VERSION")

# The compiled workloads, at -O2, and the text that xz, sha256sum and awk_words read: 8 MB from
# guest/aok/gen_data.py, which is deterministic.
step "CoreMark at $COREMARK_COMMIT, n-body and the text"
mkdir -p /opt/bench/bin
rm -rf /opt/src/coremark
git clone -q https://github.com/eembc/coremark /opt/src/coremark
git -C /opt/src/coremark checkout -q "$COREMARK_COMMIT"
(cd /opt/src/coremark && gcc -O2 -I. -Iposix -DFLAGS_STR='"-O2"' -DPERFORMANCE_RUN=1 \
  -DITERATIONS=0 core_list_join.c core_main.c core_matrix.c core_state.c core_util.c \
  posix/core_portme.c -o /opt/bench/bin/coremark -lrt)
gcc -O2 -o /opt/bench/bin/nbody "$BENCH_DIR/guest/aok/nbody.c" -lm
python3 "$BENCH_DIR/guest/aok/gen_data.py" /opt/bench/data.bin 8

# xonsh shows a welcome screen at every start until there is a configuration file, which costs
# seconds under emulation and is not what anyone who uses xonsh sees. An empty one, then.
step "xonsh's configuration"
echo "# Left empty for the benchmarks; see utils/bench/guest/prepare.sh." >/root/.xonshrc

# Each workload's programs, as far as they can be checked without running the workloads.
step "checking"
lean --version
(cd /opt/plausible && lake build >/dev/null 2>&1 && rm -rf .lake/build) || {
  echo "lake cannot build plausible" >&2
  exit 1
}
python3 -c 'import sympy; print("sympy", sympy.__version__)'
blender -b --factory-startup --python-expr 'import bpy; print("blender", bpy.app.version_string)' \
  2>/dev/null |
  grep '^blender' || {
  echo "blender does not run" >&2
  exit 1
}
xonsh --version
echo "node $(node --version)"
/opt/prettier/node_modules/.bin/prettier --version | sed 's/^/prettier /'
gcc --version | head -1
xz --version | head -1
# CoreMark counts any run under 10 s as an error, so check its three algorithms' CRCs instead: the
# ones core_main.c expects of the 2K performance run.
/opt/bench/bin/coremark 0x0 0x0 0x66 100 7 1 2000 >/tmp/coremark.out
for crc in "crclist *: 0xe714" "crcmatrix *: 0x1fd7" "crcstate *: 0x8e3a"; do
  grep -q "$crc" /tmp/coremark.out || {
    echo "CoreMark's ${crc%% *} is wrong" >&2
    exit 1
  }
done

# The manifest: every input a result depends on. bench.py digests it to name the disk.
step "writing the manifest"
mkdir -p /opt/bench
{
  echo "lean $LEAN_VERSION $LEAN_SHA256"
  echo "plausible $PLAUSIBLE_COMMIT"
  echo "lua $LUA_VERSION $LUA_SHA256"
  echo "make $MAKE_VERSION $MAKE_SHA256"
  echo "prettier $PRETTIER_VERSION"
  echo "coremark $COREMARK_COMMIT"
  echo "aok-bench $(cat "$BENCH_DIR"/guest/aok/* | sha256sum | cut -c1-16)"
  echo "data $(sha256sum </opt/bench/data.bin | cut -c1-16)"
  echo "alpine $(cat /etc/alpine-release)"
  apk info -v 2>/dev/null | sort
} >/opt/bench/manifest
wc -l </opt/bench/manifest | sed 's/$/ lines in the manifest/'
sync
