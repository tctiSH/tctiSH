#!/usr/bin/env python3
"""Runs commands in the guest over its hvc0 console, as ssh would.

The guest has no sshd. Its hvc0 console is a getty that logs in as root, which
QEMU serves as a Unix socket. The first client to connect starts a small
command server from that login shell; every later request goes to the server,
which survives savevm and -loadvm like any other program in the guest.

As with ssh, a command runs in a fresh `sh` with no tty on stdin, stdout or
stderr. Its stdout and stderr come back separately, and its exit status is the
command's. As a module:

    with Console(socket_path) as guest:
        status, out, err = guest.run("uname -a")
        guest.put(b"...", "/tmp/file")

and as a command, for poking at a guest by hand:

    gx.py <hvc0.socket> [-i] [-t secs] [-w secs] <command>...
    gx.py <hvc0.socket> -p <local file> <guest path>

where `-i` sends stdin to the command, `-t` interrupts the command after that
long and exits 124, `-w` is how long to wait for the guest to answer (default
10 s) and `-p` copies a file in. Exit status 255 means the guest could not be
reached. GX_DEBUG=1 traces what goes over the console.

QEMU serves one connection per socket, so a second client waits until the
first has gone. Hold one Console for as long as there is work to do, and run
anything that should outlive it with nohup.
"""

import base64
import os
import re
import select
import signal
import socket
import sys
import time

#: The command server. Requests are lines `__gx <op> <id> <lines> [<arg>]`,
#: followed by that many lines of base64; anything else (a stray bootstrap line,
#: a ping meant for a login shell) is ignored. Output is raw (-opost), and ^C
#: reaches only the running command, so the server outlives a command a client
#: gave up on.
SERVER = r"""
trap : INT
while :; do
    read -r tag op n lines arg
    rc=$?
    if [ $rc -ne 0 ]; then
        [ $rc -gt 128 ] && continue
        exit 0
    fi
    [ "$tag" = __gx ] || continue
    case $op in
    ping) printf '__gx_pong %s\n' "$n" ;;
    put)
        head -n "$lines" | base64 -d > "$arg"
        printf '__gx_put %s %s\n' "$n" $? ;;
    run)
        head -n "$lines" | base64 -d > /tmp/.gx.sh
        rm -f /tmp/.gx.rc
        printf '__gx_begin %s\n' "$n"
        { sh /tmp/.gx.sh < "${arg:-/dev/null}" 2>/tmp/.gx.err; echo $? > /tmp/.gx.rc; } | cat
        rc=$(cat /tmp/.gx.rc 2>/dev/null || echo 130)
        printf '\n__gx_err %s\n' "$n"
        base64 /tmp/.gx.err
        printf '__gx_end %s %s\n' "$n" "$rc"
        [ -n "$arg" ] && rm -f "$arg" ;;
    esac
done
"""

#: Starts the server from the login shell. Short enough for ash's line editor.
#: The server itself follows as plain lines, counted, since busybox sed reads a
#: line ahead and would wait on the tty for one more. If they never come (this
#: line sat in the tty from before the login, or the client gave up), the read
#: times out and the login shell is back.
BOOT = b"stty -echo -opost; echo __gx_b''oot; sh -c \"$(timeout 5 head -n %d)\"\n" % (
    SERVER.lstrip().count("\n")
)

#: Base64 per line. The tty takes up to 4095 bytes a line in canonical mode.
LINE = 1024

DEBUG = os.environ.get("GX_DEBUG")


class Unreachable(Exception):
    """The guest did not answer, or stopped answering, on the console."""


class Console:
    """One connection to the guest's command server."""

    def __init__(self, path, wait=10.0):
        end = time.time() + wait
        while True:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(path)
                break
            except OSError as e:
                s.close()
                if time.time() > end:
                    raise Unreachable(f"can't connect to {path}: {e}") from e
                time.sleep(0.2)
        self.sock, self.buf = s, b""
        try:
            self._ready(max(end - time.time(), 2.0))
        except Unreachable:
            s.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.sock.close()

    def run(self, command, stdin=None, timeout=None, out=None):
        """Runs `command`; returns (status, stdout, stderr) as bytes.

        `stdin` is bytes for the command's stdin. `timeout` interrupts it after
        that many seconds, and the status is then 124; a command still running a
        minute after that is given up on as Unreachable. `out`, a binary file,
        gets stdout as it arrives as well, for a log or a terminal.
        """
        arg = ""
        if stdin is not None:
            arg = f"/tmp/.gx.in.{os.urandom(4).hex()}"
            self.put(stdin, arg)
        n = os.urandom(4).hex()
        self._request("run", n, command.encode(), arg)
        if not self._expect(rf"__gx_begin {n}\n".encode(), 30):
            raise Unreachable("the guest didn't start the command")

        # Stream stdout, holding back enough never to pass on part of the marker.
        marker = f"\n__gx_err {n}\n".encode()
        stdout = bytearray()
        end = time.time() + timeout if timeout else None
        interrupted = False
        while True:
            i = self.buf.find(marker)
            if i >= 0:
                chunk, self.buf = self.buf[:i], self.buf[i + len(marker) :]
                self._emit(chunk, stdout, out)
                break
            keep = len(marker) - 1
            if len(self.buf) > keep:
                chunk, self.buf = self.buf[:-keep], self.buf[-keep:]
                self._emit(chunk, stdout, out)
            if end and time.time() > end:
                if interrupted:
                    raise Unreachable("the command ignored ^C")
                self._send(b"\x03")
                interrupted = True
                end = time.time() + 60
            self._pump(0.5)

        m = self._expect(rf"([\s\S]*?)__gx_end {n} (\d+)\n".encode(), 60)
        if not m:
            raise Unreachable("the guest didn't finish the command")
        stderr = base64.b64decode(m.group(1))
        return (124 if interrupted else int(m.group(2))), bytes(stdout), stderr

    def put(self, data, path):
        """Writes `data`, bytes, to `path` in the guest."""
        n = os.urandom(4).hex()
        self._request("put", n, data, path)
        m = self._expect(rf"__gx_put {n} (\d+)\n".encode(), 60 + len(data) / 100000)
        if not m or m.group(1) != b"0":
            raise Unreachable(f"couldn't write {path} in the guest")

    def interrupt(self):
        """Sends ^C to whatever the server is running."""
        self._send(b"\x03")

    @staticmethod
    def _emit(chunk, stdout, out):
        stdout += chunk
        if out and chunk:
            out.write(chunk)
            out.flush()

    def _send(self, data):
        if DEBUG:
            sys.stderr.write(f"gx> {data[:200]!r}\n")
        self.sock.sendall(data)

    def _pump(self, timeout):
        r, _, _ = select.select([self.sock], [], [], max(timeout, 0))
        if not r:
            return False
        d = self.sock.recv(65536)
        if DEBUG:
            sys.stderr.write(f"gx< {d!r}\n")
        if not d:
            raise Unreachable("QEMU closed the console")
        self.buf += d
        return True

    def _expect(self, pattern, timeout):
        rx = re.compile(pattern)
        end = time.time() + timeout
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end() :]
                return m
            left = end - time.time()
            if left <= 0:
                return None
            self._pump(min(left, 0.5))

    def _request(self, op, n, data=b"", arg=""):
        enc = base64.b64encode(data)
        lines = [enc[i : i + LINE] for i in range(0, len(enc), LINE)]
        self._send(f"__gx {op} {n} {len(lines)} {arg}\n".encode())
        for line in lines:
            self._send(line + b"\n")

    def _ready(self, wait):
        """Gets to a command server, bootstrapping one from the login shell if needed."""
        n = os.urandom(4).hex()
        end = time.time() + wait
        first = True
        while time.time() < end:
            self._request("ping", n)
            if self._expect(rf"__gx_pong {n}\n".encode(), 2 if first else 3):
                return
            # Nothing answered: a command a client gave up on may still be
            # running, or this is still the login shell, or the guest isn't up.
            if first:
                self._send(b"\x03")
                time.sleep(0.3)
            first = False
            self._send(b"\x15" + BOOT)
            if self._expect(rb"__gx_boot\r?\n", min(3, max(end - time.time(), 0))):
                self._send(SERVER.lstrip().encode())
        raise Unreachable("the guest never answered on hvc0")


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path, args = argv[1], argv[2:]
    stdin, timeout, wait, upload = None, None, 10.0, None
    while args and args[0].startswith("-") and len(args[0]) == 2:
        flag = args.pop(0)
        if flag == "-i":
            stdin = sys.stdin.buffer.read()
        elif flag == "-t":
            timeout = float(args.pop(0))
        elif flag == "-w":
            wait = float(args.pop(0))
        elif flag == "-p":
            upload = (args.pop(0), args.pop(0))
        else:
            sys.exit(f"gx: unknown flag {flag}")
    if not args and not upload:
        sys.exit(__doc__)

    # timeout(1) and friends send TERM: interrupt the command in the guest all the same.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    guest = None
    try:
        guest = Console(path, wait)
        if upload:
            with open(upload[0], "rb") as f:
                guest.put(f.read(), upload[1])
            return 0
        status, _, err = guest.run(" ".join(args), stdin, timeout, out=sys.stdout.buffer)
        sys.stderr.buffer.write(err)
        return status
    except Unreachable as e:
        print(f"gx: {e}", file=sys.stderr)
        return 255
    except KeyboardInterrupt:
        if guest:
            guest.interrupt()
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv))
