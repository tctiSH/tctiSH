#!/usr/bin/env bash
#
# Builds StikJIT.xcframework from source.
#
# StikJIT provides the debugger side of the iOS 26+ JIT protocol: it mounts the
# developer disk image over the LocalDevVPN tunnel, attaches to a target
# process, # and answers the `brk #0x69` traps QEMU raises for its code buffer.
# We build it # rather than vendoring the framework so the only binary in the
# tree is the one StikJIT itself vendors (a prebuilt Rust FFI library).
#
# Requires xcodegen, which the flake provides:
#
#     nix develop --command ./build_stikjit.sh
#
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_DIR="${STIKJIT_SOURCE:-$BASEDIR/third-party/StikJIT}"
BUILD_DIR="$BASEDIR/build-StikJIT"

# Patched and built here, never in SOURCE_DIR.
#
# Patching the submodule in place left it permanently modified in `git status`,
# which is the sort of noise that eventually gets committed by accident. This way
# the submodule is only ever read.
WORK_DIR="$BUILD_DIR/source"

ARCHIVE_PATH="$BUILD_DIR/StikJIT"
FRAMEWORK_PATH="$ARCHIVE_PATH.xcarchive/Products/Library/Frameworks/StikJIT.framework"
OUTPUT_PATH="$BUILD_DIR/StikJIT.xcframework"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Read tctiSH's own deployment target rather than keeping a second copy of it.
# Getting this wrong doesn't fail the build -- it fails the *launch*, and only on
# the older devices we're least likely to be holding. Takes the lowest target in
# the project, since the framework has to be loadable by the oldest thing that
# embeds it.
project_deployment_target () {
    grep -oE 'IPHONEOS_DEPLOYMENT_TARGET = [0-9]+(\.[0-9]+)?;' \
        "$BASEDIR/tctiSH.xcodeproj/project.pbxproj" 2>/dev/null \
        | sed -E 's/.* = ([0-9.]+);/\1/' \
        | sort -V | head -1
}

DEPLOYMENT_TARGET="${STIKJIT_DEPLOYMENT_TARGET:-$(project_deployment_target || true)}"

if [ -z "$DEPLOYMENT_TARGET" ]; then
    echo -e "${RED}Couldn't read IPHONEOS_DEPLOYMENT_TARGET from tctiSH.xcodeproj.${NC}" >&2
    echo "Set STIKJIT_DEPLOYMENT_TARGET to build anyway." >&2
    exit 1
fi

check_env () {
    if [ ! -d "$SOURCE_DIR" ]; then
        echo -e "${RED}No StikJIT source at $SOURCE_DIR.${NC}" >&2
        echo "Initialise the submodule, or point STIKJIT_SOURCE at a checkout." >&2
        exit 1
    fi

    if [ ! -f "$SOURCE_DIR/project.yml" ]; then
        echo -e "${RED}$SOURCE_DIR has no project.yml; is it a StikJIT checkout?${NC}" >&2
        exit 1
    fi

    command -v xcodegen >/dev/null 2>&1 || {
        echo -e "${RED}'xcodegen' not found. Run inside 'nix develop'.${NC}" >&2
        exit 1
    }
}

check_env

# Takes a fresh copy of the source to build from.
#
# `--delete` makes this a reset as well as a copy: whatever last build's patches
# did is undone, so patches always apply to pristine source and never stack.
# rsync skips what hasn't changed, which matters -- the vendored Rust library is
# 92MB of the 94MB here.
stage_source () {
    mkdir -p "$WORK_DIR"
    rsync -a --delete --exclude '.git' "$SOURCE_DIR"/ "$WORK_DIR"/
}

# Fixes we need that aren't upstream yet. The submodule points at
# StikDebug/StikJIT rather than a fork of ours, so they live in patches/ and are
# applied to the copy on the way past.
#
# `patch`, deliberately, not `git apply`. The copy lives under build-StikJIT/,
# which is gitignored, and git apply treats a gitignored path as none of its
# business: it prints "Skipped patch" and **exits 0**. A patch that reports
# success and changes nothing is worse than one that fails outright.
apply_patches () {
    local patch_file name
    for patch_file in "$BASEDIR"/patches/stikjit-*.patch; do
        [ -e "$patch_file" ] || return 0
        name="$(basename "$patch_file")"

        if ! patch -p1 -d "$WORK_DIR" --forward < "$patch_file"; then
            echo -e "${RED}Failed to apply $name.${NC}" >&2
            echo "The submodule has probably moved on; the patch needs rebasing." >&2
            exit 1
        fi

        # Belt and braces, having just been caught by a silent no-op: reversing
        # it has to be possible, which it only is if it went in.
        if ! patch -p1 -d "$WORK_DIR" --reverse --dry-run --force < "$patch_file" >/dev/null 2>&1; then
            echo -e "${RED}$name reported success but isn't present.${NC}" >&2
            exit 1
        fi

        echo "  $name"
    done
}

echo -e "${GREEN}Building StikJIT from $SOURCE_DIR (iOS $DEPLOYMENT_TARGET)...${NC}"
echo "  $(git -C "$SOURCE_DIR" log -1 --format='%h %s' 2>/dev/null || echo 'not a git checkout')"

# Keep WORK_DIR; rsync resets it, and re-copying 92MB every build is a waste.
#
# The xcframework is deliberately *not* removed here. Packaging replaces it at
# the end anyway, and taking it away up front means a build that fails on the way
# -- a patch that no longer applies, say -- leaves you with nothing, having
# destroyed a framework that was working perfectly well.
rm -rf "$ARCHIVE_PATH.xcarchive"
mkdir -p "$BUILD_DIR"

echo -e "${GREEN}Staging a clean copy...${NC}"
stage_source

echo -e "${GREEN}Applying local patches...${NC}"
apply_patches

echo -e "${GREEN}Generating the Xcode project...${NC}"
(cd "$WORK_DIR" && xcodegen generate --quiet)

# IPHONEOS_DEPLOYMENT_TARGET because StikJIT's project.yml picks its own, and
# tctiSH embeds this framework in the *app*. dyld refuses to load an embedded
# framework whose minimum exceeds the running system, so a framework built for
# anything newer than tctiSH's own target would stop the app launching at all --
# not just stop JIT working, which would have been fine. Keep the two in step.
#
# GENERATE_INFOPLIST_FILE because StikJIT's project.yml specifies no `info:`, so
# xcodegen produces a framework with no Info.plist at all. An app extension will
# embed one of those quite happily; an *app* refuses, with "did not contain an
# Info.plist". tctiSH embeds it in the app -- the extension links that copy -- so
# it has to have one.
echo -e "${GREEN}Archiving...${NC}"
xcodebuild archive \
    -project "$WORK_DIR/StikJIT.xcodeproj" \
    -scheme StikJIT \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SKIP_INSTALL=NO \
    GENERATE_INFOPLIST_FILE=YES \
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

if [ ! -d "$FRAMEWORK_PATH" ]; then
    echo -e "${RED}Archive produced no framework at $FRAMEWORK_PATH.${NC}" >&2
    exit 1
fi

echo -e "${GREEN}Packaging the xcframework...${NC}"
rm -rf "$OUTPUT_PATH"
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_PATH" \
    -output "$OUTPUT_PATH"

echo -e "${GREEN}Built $OUTPUT_PATH${NC}"
