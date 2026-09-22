"""Reflows Swift, Rust and YAML line comments to a fixed width.

None of the formatters this project runs will do it, which was established by
testing rather than by reading documentation:

    swift-format   leaves comment text exactly as written
    SwiftFormat    `wrap` breaks long lines but never joins short ones
    clang-format   `ReflowComments` likewise breaks but never joins
    rustfmt        `wrap_comments` likewise breaks but never joins

So a paragraph wrapped at 60 columns and one wrapped at 99 both pass, for ever.
This fills them, and refuses to touch anything where that would cause damage:

    /* ... */ blocks         not parsed at all
    trailing comments        they share their line with code
    file headers             written `//  ` with two spaces, not one
    MARK:, TODO:, FIXME:     directives, and Xcode reads some of them
    paragraphs with a URL    moving one mid-line makes it harder to grab
    bullet lists             refilling would run the items together
    indented content         inside a doc comment that is a code sample
    ``` fenced blocks        the other way to write a doc-comment sample
    commented-out code       which refills into an unreadable, unrevivable mess

The division of labour with the real formatters is exact and deliberate: this
rewrites comments and never code, they rewrite code and never comments. Run this
first; neither can undo the other.

Usage:

    python3 reflow_comments.py [--width N] [--doc-width N] [--lines A:B]... [--check] FILE...

Doc comments get their own width because they are read as prose, in a popover or
on a docs page, rather than scanned alongside the code they sit above.

`--lines A:B` confines the reflow to lines A to B, 1-based and inclusive, and may
be repeated; it is how Dialect formats the comments it adds to files it does not
own, such as its LispKit fork. A run of comment lines is split wherever it
crosses the edge of a range, and only the parts inside are refilled, so a line
outside every range is never touched. With several files, the ranges apply to
each of them.

`--check` writes nothing and exits non-zero if any file would change, printing a
diff of what it would have done.
"""

import argparse
import difflib
import os
import re
import sys
import textwrap

#: Directives, which are addressed to a tool rather than to a reader. Xcode
#: builds its jump bar out of the first three.
DIRECTIVE = re.compile(
    r"^(MARK|TODO|FIXME|NOTE|HACK|XXX|SAFETY|swiftlint|swift-format|sourcery|periphery|rustfmt|clippy)\b",
    re.IGNORECASE,
)

#: The start of a list item. Refilling a list runs its items together.
BULLET = re.compile(r"^([-*+]|\d+\.)\s")

#: Something that must not be moved around inside a line.
URL = re.compile(r"(https?|ftp|file|mailto)://|\bwww\.")

#: Structure that prose almost never has and code almost always does. Commented-
#: out code is written `// ` with one space exactly like prose, so nothing about
#: the marker distinguishes it, and refilling it destroys both its shape and any
#: chance of uncommenting it again.
#:
#: Deliberately structural rather than keyword-based. `return`, `case` and `try`
#: are ordinary English words, whereas a line ending in an open brace is not, and
#: a false positive here costs only a paragraph left as it was.
CODE_SHAPED = re.compile(
    r"""
      [{(\[]\s*$        # ends open: the next line continues the expression
    | \}\s*$            # ends in a closing brace, which prose never does
    | ^\s*[})\]]        # starts closed: the tail of one
    | ;\s*$             # ends in a statement terminator
    | ::|=>|->|!=|==     # operators and paths that prose does not use
    | ^\S+,\s*$         # a lone argument on its own line
    """,
    re.VERBOSE,
)

#: A markdown code fence, which is how both languages embed a sample in a doc
#: comment. Everything between a pair of these is reproduced exactly.
FENCE = re.compile(r"^(```|~~~)")

#: What a tab is worth when working out how much room an indent leaves. Matches
#: `tabWidth` in .swift-format, though nothing here indents with them.
TAB_WIDTH = 4

#: Below this there is no room to wrap into, and whatever is going on is better
#: left alone than folded into a column of single words.
MINIMUM_TEXT_WIDTH = 24


class Language:
    """What the scanner needs to know to tell comments from everything else.

    The differences that matter are small but not optional. Rust's ordinary
    string literals may contain a newline, so an unterminated `"` carries into
    the next line; Swift's may not, and treating one as if it did would swallow
    the rest of the file. Each spells raw strings its own way, and Swift has a
    multi-line form that Rust does not.
    """

    def __init__(
        self,
        name,
        markers,
        doc_markers,
        multiline_string=None,
        strings_span_lines=False,
        rust_raw_strings=False,
        swift_raw_strings=False,
        block_scalars=False,
    ):
        self.name = name
        #: Longest first, or `///` is read as `//` with a stray slash.
        self.markers = sorted(markers, key=len, reverse=True)
        self.doc_markers = set(doc_markers)
        self.multiline_string = multiline_string
        self.strings_span_lines = strings_span_lines
        self.rust_raw_strings = rust_raw_strings
        self.swift_raw_strings = swift_raw_strings
        #: YAML carries arbitrary text in `|` and `>` blocks, where `#` is not a
        #: comment. Set for YAML, which uses its own scanner entirely.
        self.block_scalars = block_scalars
        self.comment = re.compile(
            r"^(?P<indent>[ \t]*)(?P<marker>" + "|".join(self.markers) + r")(?P<rest>.*)$"
        )


SWIFT = Language(
    name="Swift",
    markers=["///", "//"],
    doc_markers=["///"],
    multiline_string='"""',
    swift_raw_strings=True,
)

RUST = Language(
    name="Rust",
    markers=["///", "//!", "//"],
    doc_markers=["///", "//!"],
    strings_span_lines=True,
    rust_raw_strings=True,
)

YAML = Language(
    name="YAML",
    markers=["#"],
    #: YAML has no doc-comment convention, so everything fills to --width.
    doc_markers=[],
    block_scalars=True,
)

#: This file is shared verbatim between tctiSH and Dialect, so every language
#: stays defined here whether or not the project using it has such sources.
#: Keep the two copies identical and improvements move freely between them.
LANGUAGES = {".swift": SWIFT, ".rs": RUST, ".yml": YAML, ".yaml": YAML}


#: Opens a block scalar: `key: |`, `- >`, `key: |-`, `key: >2`, optionally with a
#: trailing comment. Everything indented under one of these is literal text.
BLOCK_SCALAR = re.compile(r"[|>](?:[0-9]|[+-]){0,2}[ \t]*(?:#.*)?$")


def scan_yaml_comment_starts(lines):
    """Returns, per line, whether it begins a full-line YAML comment.

    YAML needs its own scanner rather than the character walk below, because the
    hazard is different in kind. There are no string-delimiter rules to carry
    across lines; there are block scalars, whose contents are arbitrary text.
    A `run: |` step holding a shell script would otherwise have its `#` lines
    read as YAML comments and rewrapped, silently corrupting the script.

    Known limitation: a `#` at the start of a continuation line of a multi-line
    *quoted* scalar is treated as a comment. That construction is vanishingly
    rare, and the alternative is a full YAML parse.
    """
    starts = [False] * len(lines)
    in_block = False
    block_indent = 0

    for number, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        if in_block:
            # Blank lines belong to the block; dedenting to the opener's level
            # or further ends it.
            if not stripped:
                continue
            if indent > block_indent:
                continue
            in_block = False

        if stripped.startswith("#"):
            starts[number] = True
            continue

        if BLOCK_SCALAR.search(line):
            in_block = True
            block_indent = indent

    return starts


def display_width(indent):
    """Returns how many columns `indent` occupies once tabs are expanded."""
    return len(indent.expandtabs(TAB_WIDTH))


def scan_for_comment_starts(lines, language):
    """Returns, per line, whether it begins a line comment at the top level.

    A line-by-line regex cannot answer this on its own: `//` at the start of a
    line inside a string literal, or inside a `/* */` block, is text rather than
    a comment, and rewrapping it would corrupt the program. So this walks the
    file as characters, carrying string and block-comment state across the line
    boundaries.
    """
    if language.block_scalars:
        return scan_yaml_comment_starts(lines)

    starts = [False] * len(lines)
    block_depth = 0
    open_multiline = False
    open_string = False
    open_raw = None  # The closing delimiter we are looking for, if any.

    for number, line in enumerate(lines):
        index = 0
        length = len(line)
        stripped = line.lstrip()
        at_top_level_start = (
            block_depth == 0 and not open_multiline and not open_string and open_raw is None
        )

        while index < length:
            rest = line[index:]

            if open_raw is not None:
                if rest.startswith(open_raw):
                    index += len(open_raw)
                    open_raw = None
                else:
                    index += 1
                continue

            if open_multiline:
                if rest.startswith(language.multiline_string):
                    open_multiline = False
                    index += len(language.multiline_string)
                else:
                    index += 1
                continue

            if open_string:
                if line[index] == "\\":
                    index += 2
                    continue
                if line[index] == '"':
                    open_string = False
                index += 1
                continue

            if block_depth:
                # Both languages nest block comments, so both ends are counted.
                if rest.startswith("/*"):
                    block_depth += 1
                    index += 2
                elif rest.startswith("*/"):
                    block_depth -= 1
                    index += 2
                else:
                    index += 1
                continue

            if rest.startswith("//"):
                # The rest of the line is comment, whatever it holds. It counts
                # as one we may rewrite only if nothing preceded it.
                starts[number] = at_top_level_start and stripped.startswith("//")
                break

            if rest.startswith("/*"):
                block_depth += 1
                index += 2
                continue

            raw = raw_string_opener(rest, language)
            if raw is not None:
                opener, closer = raw
                open_raw = closer
                index += len(opener)
                continue

            if language.multiline_string and rest.startswith(language.multiline_string):
                open_multiline = True
                index += len(language.multiline_string)
                continue

            if rest.startswith('"'):
                open_string = True
                index += 1
                continue

            index += 1

        # An ordinary string cannot survive a newline in Swift, so an
        # unterminated one is a syntax error rather than something to carry.
        if not language.strings_span_lines:
            open_string = False

    return starts


def raw_string_opener(rest, language):
    """If `rest` opens a raw string, returns its opener and its closer."""
    if language.rust_raw_strings:
        match = re.match(r'(b?r(#*)")', rest)
        if match:
            return match.group(1), '"' + "#" * len(match.group(2))

    if language.swift_raw_strings:
        match = re.match(r'(#+)("""|")', rest)
        if match:
            hashes, quote = match.groups()
            return hashes + quote, quote + hashes

    return None


def is_reflowable(text):
    """Whether a line's comment text may be merged with its neighbours."""
    return not (
        DIRECTIVE.match(text) or BULLET.match(text) or URL.search(text) or CODE_SHAPED.search(text)
    )


def reflow_run(rests, indent, marker, width):
    """Reflows one run of comment lines, all at the same indent and marker.

    `rests` is what followed the marker on each line, markers already removed.
    """
    available = width - display_width(indent) - len(marker) - 1
    prefix = f"{indent}{marker} "
    wrapper = textwrap.TextWrapper(
        width=max(available, MINIMUM_TEXT_WIDTH),
        break_long_words=False,
        break_on_hyphens=False,
    )

    output = []
    paragraph = []
    fenced = False

    def flush():
        if not paragraph:
            return
        if available < MINIMUM_TEXT_WIDTH:
            # No room to wrap into. Put it back exactly as it came.
            output.extend(f"{prefix}{line}" for line in paragraph)
        else:
            output.extend(f"{prefix}{line}" for line in wrapper.wrap(" ".join(paragraph)))
        paragraph.clear()

    for rest in rests:
        # Prose is one space after the marker. Two is the file-header
        # convention, and more than that is a code sample, so both fall through
        # to being reproduced verbatim.
        text = rest[1:] if rest.startswith(" ") and not rest.startswith("  ") else None
        body = text.strip() if text else ""

        if body and FENCE.match(body):
            flush()
            fenced = not fenced
            output.append(f"{indent}{marker}{rest}".rstrip())
            continue

        if fenced or text is None or not body or not is_reflowable(body):
            flush()
            output.append(f"{indent}{marker}{rest}".rstrip())
            continue

        paragraph.append(body)

    flush()
    return output


def reflow(text, language, width, doc_width, ranges=None):
    """Returns `text` with every reflowable comment paragraph refilled.

    `ranges`, if given, is a list of `(first, last)` line numbers, 1-based and
    inclusive: only comment lines inside one of them are refilled.
    """
    lines = text.split("\n")
    starts = scan_for_comment_starts(lines, language)

    def in_range(index):
        return ranges is None or any(first <= index + 1 <= last for first, last in ranges)

    output = []
    index = 0

    while index < len(lines):
        if not starts[index]:
            output.append(lines[index])
            index += 1
            continue

        first = language.comment.match(lines[index])
        indent, marker = first["indent"], first["marker"]

        # A run is broken by a change of either, so a `///` block below a `//`
        # one, or a differently indented continuation, is reflowed separately.
        # So is one that crosses the edge of a range, and the part outside is
        # reproduced exactly as it was.
        inside = in_range(index)
        begin = index
        rests = []
        while index < len(lines) and starts[index]:
            current = language.comment.match(lines[index])
            if current["indent"] != indent or current["marker"] != marker:
                break
            if in_range(index) != inside:
                break
            rests.append(current["rest"])
            index += 1

        if not inside:
            output.extend(lines[begin:index])
            continue

        target = doc_width if marker in language.doc_markers else width
        output.extend(reflow_run(rests, indent, marker, target))

    return "\n".join(output)


def line_range(value):
    """Parses `A:B` for `--lines`."""
    try:
        first, last = (int(part) for part in value.split(":"))
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected A:B, got {value!r}") from None
    if not 1 <= first <= last:
        raise argparse.ArgumentTypeError(f"expected 1 <= A <= B, got {value!r}")
    return (first, last)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("files", nargs="+", metavar="FILE")
    parser.add_argument("--width", type=int, default=100, help="columns to fill comments to")
    parser.add_argument(
        "--doc-width",
        type=int,
        default=None,
        help="columns to fill doc comments to; defaults to --width",
    )
    parser.add_argument(
        "--lines",
        action="append",
        type=line_range,
        metavar="A:B",
        help="refill only comments within lines A to B (1-based, inclusive); repeatable",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="write nothing; exit non-zero if any file would change",
    )
    args = parser.parse_args(argv)
    doc_width = args.width if args.doc_width is None else args.doc_width

    changed = []

    for path in args.files:
        language = LANGUAGES.get(os.path.splitext(path)[1])
        if language is None:
            print(f"reflow-comments: {path}: unsupported file type", file=sys.stderr)
            return 2

        with open(path, encoding="utf-8", newline="") as handle:
            original = handle.read()

        updated = reflow(original, language, args.width, doc_width, args.lines)
        if updated == original:
            continue

        changed.append(path)

        if args.check:
            sys.stdout.writelines(
                difflib.unified_diff(
                    original.splitlines(keepends=True),
                    updated.splitlines(keepends=True),
                    fromfile=path,
                    tofile=f"{path} (reflowed)",
                )
            )
        else:
            with open(path, "w", encoding="utf-8", newline="") as handle:
                handle.write(updated)

    return 1 if (args.check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
