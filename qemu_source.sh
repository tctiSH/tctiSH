# shellcheck shell=bash
#
# Getting the QEMU checkout ready to configure. Expects QEMU_DIR and BASEDIR to
# be set, and GREEN and NC for its messages.

# QEMU is not downloaded: it is the third-party/qemu submodule, tctiSH's fork
# (tctiSH/qemu, branch tctish-edition), and every tctiSH change to it is a
# commit there. The build directories live under $BUILD_DIR, so the checkout
# itself is never written to by a build and can be edited, committed and
# rebased like any other tree.
#
# What a checkout lacks, where a release tarball has it, is the meson
# subprojects its wraps name. They are fetched here, with the rest of the
# downloads, rather than by configure several minutes in -- the build then
# passes --disable-download, so a network failure can only happen up front.
# This is also the list configure would fetch: keep it to what this build
# configures, since some wraps are large and none of the rest are used.
QEMU_SUBPROJECTS="keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3 slirp libucontext"

prepare_qemu_source() {
    if [ ! -f "$QEMU_DIR/configure" ]; then
        echo "${GREEN}Checking out the QEMU submodule...${NC}"
        git -C "$BASEDIR" submodule update --init third-party/qemu
    fi
    for sub in $QEMU_SUBPROJECTS; do
        drop_stale_qemu_subproject "$sub"
    done
    echo "${GREEN}Fetching QEMU's meson subprojects...${NC}"
    (cd "$QEMU_DIR" && meson subprojects download $QEMU_SUBPROJECTS)
}

# `meson subprojects download` skips a subproject whose directory already
# exists, and --disable-download keeps configure from fetching one, so after a
# rebase onto a release whose wrap moved the build would go on using the old
# checkout without a word. Such a checkout is removed here so the download
# replaces it.
#
# Only a pinned revision (a full commit hash, which every wrap this build uses
# has) can be compared. A branch or tag would never match HEAD, and removing on
# that basis would put a clone back in every build.
drop_stale_qemu_subproject() {
    wrap="$QEMU_DIR/subprojects/$1.wrap"
    dir="$QEMU_DIR/subprojects/$1"
    [ -d "$dir/.git" ] || return 0

    want="$(sed -n 's/^revision *= *//p' "$wrap")"
    overlay="$(sed -n 's/^patch_directory *= *//p' "$wrap")"
    stale=

    if echo "$want" | grep -Eq '^[0-9a-f]{40}$' &&
        [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$want" ]; then
        stale="it is not at the wrap's revision"
    fi
    if [ -n "$overlay" ] && [ -d "$QEMU_DIR/subprojects/packagefiles/$overlay" ]; then
        # The overlay is copied over the clone, so each of its files must be
        # there as it is now.
        for f in $(cd "$QEMU_DIR/subprojects/packagefiles/$overlay" && find . -type f); do
            if ! cmp -s "$QEMU_DIR/subprojects/packagefiles/$overlay/$f" "$dir/$f"; then
                stale="its packagefiles overlay has changed"
            fi
        done
    fi

    if [ -n "$stale" ]; then
        echo "${GREEN}Removing QEMU subproject $1, as ${stale}...${NC}"
        rm -rf "$dir"
    fi
}
