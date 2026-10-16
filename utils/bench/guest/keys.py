"""Types into an interactive program on a pty, a key at a time, and times each key.

    python3 keys.py [--quiet SECS] [--settle SECS] <text> -- <program> [args...]

The prompt counts as drawn once the program has printed something and then been silent for
`--settle` seconds. A key's latency runs from writing it to the last byte of the response, the
response ending at the first `--quiet` seconds of silence: the time until the screen stops changing.
The quiet period must exceed any pause within one response, and costs nothing, as it isn't counted.
Finally it types Ctrl-U and `exit`.

Prints @metric lines (see lib.sh): time to the first prompt, and the keys' median and 90th
percentile latencies, with each key's as @info. Answers prompt_toolkit's cursor position query,
which it waits for before drawing.
"""

import argparse
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

ROWS, COLUMNS = 40, 100


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet", type=float, default=0.5)
    parser.add_argument("--settle", type=float, default=3.0)
    parser.add_argument("text")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", COLUMNS=str(COLUMNS), LINES=str(ROWS))
        os.execvp(argv[0], argv)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLUMNS, 0, 0))

    def respond(first, quiet):
        """Waits up to `first` for output to start, then until `quiet` passes without any.

        Returns the time of the last byte, or None if nothing came.
        """
        last = None
        while True:
            ready, _, _ = select.select([fd], [], [], quiet if last else first)
            if not ready:
                return last
            try:
                data = os.read(fd, 65536)
            except OSError:
                return last
            if not data:
                return last
            last = time.monotonic()
            if b"\x1b[6n" in data:
                os.write(fd, b"\x1b[1;1R")

    start = time.monotonic()
    prompt = respond(600, args.settle)
    if prompt is None:
        print("@fail the program printed nothing")
        sys.exit(1)
    print(f"@metric prompt {prompt - start:.2f} s", flush=True)

    latencies = []
    for key in args.text:
        sent = time.monotonic()
        os.write(fd, key.encode())
        done = respond(60, args.quiet)
        if done is None:
            print(f"@fail no response to the key {key!r}")
            sys.exit(1)
        latencies.append(done - sent)

    os.write(fd, b"\x15exit\r")
    respond(60, args.quiet)
    os.waitpid(pid, 0)

    ms = sorted(1000 * x for x in latencies)
    print("@info key_runs " + " ".join(f"{1000 * x:.0f}" for x in latencies))
    print(f"@metric key_median {ms[len(ms) // 2]:.0f} ms")
    print(f"@metric key_p90 {ms[min(len(ms) - 1, int(len(ms) * 0.9))]:.0f} ms")


if __name__ == "__main__":
    main()
