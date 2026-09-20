#!/usr/bin/env bash
#
# Regenerates third-party/dependencies/qemu-10.0.12-utm.patch from an edited
# QEMU source tree.
#
# There is no checkout to commit to: the working tree is build-iOS-arm64/<name>/,
# which build_dependencies.sh re-extracts and re-patches on every clean build.
# So an edit made there and not captured here is an edit that disappears the
# next time anyone runs a clean build.
#
# The workflow is therefore:
#
#   1. edit build-iOS-arm64/<name>/...
#   2. run this
#   3. rebuild, and check the patch still applies from scratch
#
# Run it before a clean build, not after.
set -euo pipefail

BASEDIR="$(dirname "$(dirname "$(realpath "$0")")")"
cd "$BASEDIR"

PATCHES_DIR="third-party/dependencies"
source "$PATCHES_DIR/sources"

FILE="$(basename "$QEMU_SRC")"
NAME="${FILE%.tar.*}"
WORKING="build-iOS-arm64/$NAME"
TARBALL="build-iOS-arm64/$FILE"
PATCH="$PATCHES_DIR/$NAME.patch"

[ -d "$WORKING" ] || {
    echo "no source tree at $WORKING; run a build first" >&2
    exit 1
}
[ -f "$TARBALL" ] || {
    echo "no tarball at $TARBALL; run a build first" >&2
    exit 1
}
[ -f "$PATCH" ] || {
    echo "no patch at $PATCH" >&2
    exit 1
}

# The set of files the patch covers, read back out of the patch itself rather
# than listed here, so adding a file means editing one place and not two. Any
# extra paths on the command line join them, which is how a file gets in for the
# first time -- after that it is in the patch and needs no argument.
mapfile -t FILES < <({
    grep '^diff --git' "$PATCH" | sed 's|^diff --git a/||; s| b/.*||'
    printf '%s\n' "$@"
} | sed '/^$/d' | sort -u)
echo "regenerating ${#FILES[@]} files"

# Every temporary named before anything can fail, and one trap covering the lot.
# Two of these are full QEMU extractions, so leaking them on an early exit costs
# about a gigabyte.
PRISTINE="$(mktemp -d)"
CHECK="$(mktemp -d)"
NEW="$(mktemp)"
trap 'rm -rf "$PRISTINE" "$CHECK" "$NEW"' EXIT

tar -xf "$TARBALL" -C "$PRISTINE"

# Everything above the first "diff --git" is the hand-written explanation, and
# is kept verbatim.
sed '/^diff --git/,$d' "$PATCH" >"$NEW"

for f in "${FILES[@]}"; do
    a="$PRISTINE/$NAME/$f"
    b="$WORKING/$f"

    [ -f "$b" ] || {
        echo "missing from the working tree: $f" >&2
        exit 1
    }

    # A file the patch adds rather than changes -- configs/meson/<host>.txt is
    # the obvious candidate, since configure picks those up by name. Without
    # this, diff is handed a path that does not exist and writes a hunk that
    # applies to nothing.
    if [ ! -f "$a" ]; then
        printf 'diff --git a/%s b/%s\n' "$f" "$f" >>"$NEW"
        printf 'new file mode 100644\n' >>"$NEW"
        diff -u --label /dev/null --label "b/$f" /dev/null "$b" >>"$NEW" && rc=0 || rc=$?
        # 0 same, 1 differ, 2 something went wrong. Only the last is a problem,
        # and `|| true` used to swallow it and write a truncated hunk.
        [ "$rc" -le 1 ] || {
            echo "diff failed on $f (exit $rc)" >&2
            exit 1
        }
        echo "  $f (new file)"
        continue
    fi

    if cmp -s "$a" "$b"; then
        echo "  unchanged, dropping: $f"
        continue
    fi

    # git-style headers, so the result applies with -p1 exactly as before.
    printf 'diff --git a/%s b/%s\n' "$f" "$f" >>"$NEW"
    diff -u --label "a/$f" --label "b/$f" "$a" "$b" >>"$NEW" && rc=0 || rc=$?
    [ "$rc" -le 1 ] || {
        echo "diff failed on $f (exit $rc)" >&2
        exit 1
    }
    echo "  $f"
done

# Checked before the existing patch is touched, not after.
#
# The old order wrote the new patch into place and then verified it, so a
# regeneration that produced something unusable destroyed the only good copy on
# its way to reporting the problem -- which is the one failure the check exists
# to prevent.
tar -xf "$TARBALL" -C "$CHECK"
if ! patch -d "$CHECK/$NAME" -p1 --dry-run <"$NEW" >/dev/null 2>&1; then
    cp "$NEW" "$PATCH.rejected"
    echo "does not apply to a fresh extraction; $PATCH left alone" >&2
    echo "the rejected version is at $PATCH.rejected" >&2
    exit 1
fi

mv "$NEW" "$PATCH"
echo "wrote $PATCH -- applies cleanly to a fresh extraction"
