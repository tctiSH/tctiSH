#!/usr/bin/env bash
#
# Records, and checks, what each checked-in guest image was built from.
#
#   image_stamps.sh stamp IMAGE INPUT...    after building IMAGE from INPUTs
#   image_stamps.sh check IMAGE INPUT...    whether IMAGE is still what they build
#
# assets/images.sha256 holds a line per image: its path, its sha256, and a digest of its inputs'
# paths, contents and executable bits as the build saw them. The build rules in the Makefile stamp each image as
# they make it, and `make check-images` checks all of them against the inputs as they are now. It
# fails for an input that changed without the image being rebuilt, and for an image that changed
# without a build to stamp it. Bytes are what count: an edit to a comment is a change.
set -euo pipefail

STAMPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/images.sha256"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | cut -d' ' -f1
  else
    shasum -a 256 "$@" | cut -d' ' -f1
  fi
}

# The digest of the inputs: each one's path, the sha256 of its contents and whether it is
# executable (which git keeps, and the image does too), in a fixed order, so that it is the same in
# any checkout.
inputs_digest() {
  local f
  printf '%s\n' "$@" | LC_ALL=C sort -u | while IFS= read -r f; do
    if [ ! -f "$f" ]; then
      echo "$f: an input is missing" >&2
      exit 1
    fi
    printf '%s %s %s\n' "$f" "$(sha256 "$f")" "$([ -x "$f" ] && echo x || echo -)"
  done | sha256
}

mode="${1:-}"
image="${2:-}"
[ -n "$mode" ] && [ -n "$image" ] && [ $# -ge 3 ] || {
  echo "usage: $(basename "$0") stamp|check IMAGE INPUT..." >&2
  exit 2
}
shift 2

case "$mode" in
  stamp)
    line="$image $(sha256 "$image") $(inputs_digest "$@")"
    touch "$STAMPS"
    {
      awk -v image="$image" '$1 != image' "$STAMPS"
      echo "$line"
    } | LC_ALL=C sort >"$STAMPS.new"
    mv "$STAMPS.new" "$STAMPS"
    ;;
  check)
    recorded="$(awk -v image="$image" '$1 == image' "$STAMPS" 2>/dev/null || true)"
    if [ -z "$recorded" ]; then
      echo "$image: not stamped; build it with make to record what it is built from" >&2
      exit 1
    fi
    read -r _ image_sha inputs_sha <<<"$recorded"
    if [ "$(sha256 "$image")" != "$image_sha" ]; then
      echo "$image: changed since it was stamped; build it with make rather than copying it in" >&2
      exit 1
    fi
    if [ "$(inputs_digest "$@")" != "$inputs_sha" ]; then
      echo "$image: its inputs changed since it was built; rebuild it with make" >&2
      exit 1
    fi
    echo "$image: up to date"
    ;;
  *)
    echo "$(basename "$0"): unknown mode '$mode'" >&2
    exit 2
    ;;
esac
