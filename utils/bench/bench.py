#!/usr/bin/env python3
"""tctiSH's benchmark suite: real programs, timed in the guest on our QEMU, on this Mac.

    bench.py prepare [--qemu PATH]
    bench.py baseline COMMIT [--name NAME]
    bench.py run --backend tcti|jit [--workloads A,B,...] [--rounds N] [--label NAME]
                 [--qemu PATH] [--wait-quiet LOAD] [--replace]
    bench.py compare LABEL [LABEL...]
    bench.py list

`prepare` makes build-bench/bench.qcow, the app's empty disk with the workloads' programs
installed; it boots on the JIT and needs the network. `baseline` builds the hybrid QEMU from
another fork commit, into build-macOS-arm64/qemu_hybrid-<name>. `run` boots each workload
separately on a fresh copy of the disk, once per round, and appends the results to
build-bench/results/<label>.jsonl. `compare` tabulates labels against the first. `list` names the
workloads.

The QEMU is build-macOS-arm64/qemu_hybrid, the build the app ships, started on --backend; --qemu
runs another, such as a baseline. The guest and machine are the app's, so TCTI runs here as on a
device, but nothing behind TARGET_OS_IPHONE is tested, and a device's speed differs from this Mac's.

Workloads are utils/bench/workloads/*.sh; guest/lib.sh documents how they report. See README.md.
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OUT = REPO / "build-bench"
DISK = OUT / "bench.qcow"
MANIFEST = OUT / "bench.manifest"
RESULTS = OUT / "results"
RUNS = OUT / "runs"
ASSETS = REPO / "assets"
DEFAULT_QEMU = REPO / "build-macOS-arm64" / "qemu_hybrid" / "qemu-system-x86_64"

#: The machine, as qemu_launcher.c and assets/boot_guest.sh spell it. Bump with the QEMU upgrade
#: that moves the app's default, as boot_guest.sh does.
MACHINE = "pc-i440fx-11.1"
CPU = "Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl"
CMDLINE = (
    "tcti_disk=file page_reporting.page_reporting_order=2 "
    "console=ttyS0 earlyprintk=serial,ttyS0 rcupdate.rcu_cpu_stall_suppress=1"
)
#: Fixed rather than the app's settings, so that every run has the same machine. The app's code
#: cache on Auto comes to 1 GiB on a 16 GB device, which is what tb-size asks for here. 4 GiB of RAM
#: leaves room for Lean's parallel build and Blender's render.
MEMORY = "4G"
CPUS = 4
TB_SIZE = 1024

#: How long one workload may take before it is interrupted. Lean under TCTI takes a few minutes on
#: an M2 Max; this is for a build that has gone wrong, not a slow one.
WORKLOAD_TIMEOUT = 3600

#: Where the workloads and the files they use are copied to in the guest, at every boot.
GUEST_DIR = "/tmp/bench"


def die(message):
    print(f"bench: {message}", file=sys.stderr)
    sys.exit(1)


def note(message):
    print(f"==> {message}", flush=True)


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()[:12]


def workloads():
    """Every workload, by name, with the summary line from its script."""
    found = {}
    for path in sorted((HERE / "workloads").glob("*.sh")):
        summary = ""
        for line in path.read_text().splitlines():
            if line.startswith("# summary:"):
                summary = line.split(":", 1)[1].strip()
                break
        found[path.stem] = summary
    return found


# -- The emulator ---------------------------------------------------------------------------------


class Build:
    """A QEMU binary, and how to start it on a backend."""

    def __init__(self, path, backend):
        self.path = Path(path).resolve()
        if not os.access(self.path, os.X_OK):
            die(f"no QEMU at {self.path}; `make bench` builds the hybrid, or ./build_host_qemu.sh")
        self.backend = backend
        self.bios = self.path.parent / "pc-bios"
        if not self.bios.is_dir():
            die(f"no pc-bios directory next to {self.path}")
        self.hybrid = self._is_hybrid()
        # The app asks the console device to carry the terminal's size, which the fork added on
        # 2026-10-13. It has no bearing on speed, so a build from before it, such as a baseline,
        # runs without.
        device = subprocess.run(
            [self.path, "-device", "virtio-serial-pci,help"], capture_output=True, text=True
        )
        self.serial = "virtio-serial-pci,id=vser0" + (
            ",console-size=on" if "console-size=" in device.stdout else ""
        )
        if not self.hybrid:
            # build_host_qemu.sh names a standalone build after its backend.
            name = self.path.parent.name
            for only in ("tcti", "jit"):
                if name.startswith(f"qemu_{only}") and backend != only:
                    die(f"{name} has only the {only} backend, not {backend}")

    def _is_hybrid(self):
        # A hybrid build has the tcti property, so rejects a bad value for it; any other build
        # rejects the property itself. Either way QEMU exits at once.
        probe = subprocess.run(
            [self.path, "-M", "none", "-display", "none", "-accel", "tcg,tcti=probe"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return "expects 'on' or 'off'" in probe.stderr

    @property
    def accel(self):
        # The hybrid as qemu_launcher.c starts it. A standalone build has no tcti option, and only
        # the JIT uses split-wx.
        if self.hybrid:
            tcti = "on" if self.backend == "tcti" else "off"
            return f"tcg,tcti={tcti},split-wx=on,tb-size={TB_SIZE}"
        if self.backend == "tcti":
            return f"tcg,tb-size={TB_SIZE}"
        return f"tcg,split-wx=on,tb-size={TB_SIZE}"

    def identity(self):
        """What a result depends on, beside the disk and the workloads."""
        ident = {
            "qemu": str(self.path),
            "qemu_digest": digest_file(self.path),
            "hybrid": self.hybrid,
            "backend": self.backend,
            "accel": self.accel,
            "kernel": digest_file(ASSETS / "bzImage"),
            "initrd": digest_file(ASSETS / "initrd.img"),
        }
        if self.path == DEFAULT_QEMU:
            ident["fork"] = fork_version()
        return ident


def fork_version():
    """The third-party/qemu checkout the default build comes from, as a short commit."""
    qemu = REPO / "third-party" / "qemu"
    try:
        head = subprocess.run(
            ["git", "-C", qemu, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        dirty = subprocess.run(
            ["git", "-C", qemu, "status", "--porcelain", "--untracked-files=no"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return head + ("-dirty" if dirty else "")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Monitor:
    """QEMU's human monitor, over TCP."""

    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=30)
        self._read()

    def _read(self):
        buf = b""
        while not buf.rstrip().endswith(b"(qemu)"):
            chunk = self.sock.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
        return buf.decode(errors="replace")

    def __call__(self, command):
        self.sock.sendall(command.encode() + b"\n")
        return self._read()

    def close(self):
        self.sock.close()


class Machine:
    """One boot of the guest on the given disk, driven over hvc0."""

    def __init__(self, build, disk, run_dir):
        self.build, self.disk, self.dir = build, disk, run_dir
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "share").mkdir(exist_ok=True)
        # /tmp, as a Unix socket's path must fit in 104 bytes.
        self.hvc0 = f"/tmp/tctish-bench.{os.getpid()}.hvc0"
        self.port = free_port()
        self.process = None
        self.guest = None

    def argv(self):
        b = self.build
        slots = min(os.cpu_count() or CPUS, 16)
        argv = [
            b.path, "-L", b.bios,
            "-M", MACHINE,
            "-m", MEMORY,
            "-smp", f"cpus={CPUS},maxcpus={slots},sockets=1,cores={slots},threads=1",
            "-cpu", CPU,
            "-accel", b.accel,
            "-kernel", ASSETS / "bzImage",
            "-initrd", ASSETS / "initrd.img",
            "-display", "none",
            "-device", "virtio-net-pci,id=net1,netdev=net0",
            "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100",
            "-device", b.serial,
            "-device", "virtconsole,id=hvc0,chardev=hvc0-socket,bus=vser0.0",
            "-chardev", f"socket,id=hvc0-socket,path={self.hvc0},server=on,wait=off",
            "-device", "virtserialport,id=agent,chardev=agent-socket,bus=vser0.0,"
                       "name=io.ara.tctish.agent",
            "-chardev", "null,id=agent-socket",
            "-device", "virtserialport,id=control,chardev=control-socket,bus=vser0.0,"
                       "name=io.ara.tctish.control",
            "-chardev", "null,id=control-socket",
            "-device", "virtio-rng-pci",
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            "-device", f"virtio-blk-pci,id=disk1,drive=drive1,num-queues={slots}",
            "-drive", f"file={self.disk},id=drive1,if=none,format=qcow2,discard=unmap,"
                      "detect-zeroes=unmap",
            "-fsdev", f"local,path={self.dir / 'share'},security_model=none,id=fsdev0",
            "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=shared",
            "-monitor", f"tcp:127.0.0.1:{self.port},server=on,wait=off",
            "-serial", f"file:{self.dir / 'serial.log'}",
            "-no-reboot",
            "-append", CMDLINE,
        ]  # fmt: skip
        # The consoles of the app's other TTYs, hvc1 to hvc11, connected to nothing here.
        for n in range(1, 12):
            argv += ["-device", f"virtconsole,id=hvc{n},chardev=hvc{n}-socket,bus=vser0.0"]
            argv += ["-chardev", f"null,id=hvc{n}-socket"]
        return [str(a) for a in argv]

    def __enter__(self):
        try:
            os.unlink(self.hvc0)
        except FileNotFoundError:
            pass
        with open(self.dir / "qemu.log", "w") as log:
            self.process = subprocess.Popen(self.argv(), stdout=log, stderr=log)
        end = time.time() + 600
        while True:
            if self.process.poll() is not None:
                die(f"QEMU exited during boot; see {self.dir / 'qemu.log'}")
            try:
                self.guest = gx.Console(self.hvc0, wait=30)
                return self
            except gx.Unreachable:
                if time.time() > end:
                    self.kill()
                    die(f"the guest never came up; see {self.dir / 'serial.log'}")

    def run(self, command, timeout=None, out=None):
        status, stdout, stderr = self.guest.run(command, timeout=timeout, out=out)
        return status, stdout.decode(errors="replace"), stderr.decode(errors="replace")

    def put(self, local, remote):
        self.guest.put(Path(local).read_bytes(), remote)

    def power_down(self):
        """Shuts the guest down cleanly, for a disk that is kept."""
        self.run("sync")
        try:
            monitor = Monitor(self.port)
            monitor("system_powerdown")
            monitor.close()
            self.process.wait(60)
        except (OSError, subprocess.TimeoutExpired):
            print("bench: the guest did not power down; stopping QEMU", file=sys.stderr)
        self.kill()

    def kill(self):
        if self.guest:
            self.guest.close()
            self.guest = None
        if self.process and self.process.poll() is None:
            try:
                monitor = Monitor(self.port)
                monitor("quit")
                monitor.close()
                self.process.wait(30)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        try:
            os.unlink(self.hvc0)
        except FileNotFoundError:
            pass

    def __exit__(self, *_):
        self.kill()


def clone(source, dest):
    """A copy of a disk, as an APFS clone where it can be: instant, and no space until written."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.unlink(missing_ok=True)
    # macOS's cp, by path: a cp from nix or Homebrew is GNU's, which has no -c.
    if subprocess.run(["/bin/cp", "-c", source, dest], capture_output=True).returncode != 0:
        shutil.copyfile(source, dest)


# -- prepare --------------------------------------------------------------------------------------


def prepare(args):
    empty = ASSETS / "empty.qcow"
    if not empty.exists():
        die(f"no {empty}; run: make guest")
    build = Build(args.qemu, "jit")
    OUT.mkdir(exist_ok=True)
    partial = OUT / "bench.qcow.partial"
    clone(empty, partial)
    run_dir = RUNS / "prepare"
    shutil.rmtree(run_dir, ignore_errors=True)

    note(f"booting {build.path} on the JIT to install the workloads")
    with Machine(build, partial, run_dir) as m, open(run_dir / "prepare.log", "wb") as log:
        m.put(HERE / "guest" / "prepare.sh", "/tmp/prepare.sh")

        class Tee:
            def write(self, data):
                log.write(data)
                sys.stdout.buffer.write(data)

            def flush(self):
                log.flush()
                sys.stdout.buffer.flush()

        status, _, err = m.run("sh /tmp/prepare.sh", timeout=4 * 3600, out=Tee())
        if status != 0:
            sys.stderr.write(err)
            die(f"preparing the disk failed (status {status}); the log is {run_dir}")
        status, manifest, _ = m.run("cat /opt/bench/manifest")
        if status != 0:
            die("the guest wrote no manifest")
        note("powering the guest down")
        m.power_down()

    partial.replace(DISK)
    MANIFEST.write_text(manifest)
    note(f"wrote {DISK.relative_to(REPO)}, disk {disk_id()}")


def disk_id():
    if not DISK.exists() or not MANIFEST.exists():
        die("no benchmark disk; run: make bench-disk")
    return hashlib.sha256(MANIFEST.read_bytes()).hexdigest()[:12]


# -- baseline -------------------------------------------------------------------------------------


def baseline(args):
    """Builds the hybrid QEMU from a fork commit, beside the default build, to compare against."""
    qemu = REPO / "third-party" / "qemu"
    try:
        commit = subprocess.run(
            ["git", "-C", qemu, "rev-parse", "--short", f"{args.commit}^{{commit}}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        die(f"{args.commit} is not a commit in third-party/qemu")
    name = args.name or commit
    build = REPO / "build-macOS-arm64" / f"qemu_hybrid-{name}" / "qemu-system-x86_64"

    # A copy of the commit, not a worktree, so the submodule's checkout is never touched. meson's
    # subprojects come from the checkout: git does not track them, so a fresh tree would have to
    # download them again.
    src = OUT / "src" / name
    shutil.rmtree(src, ignore_errors=True)
    src.mkdir(parents=True)
    note(f"extracting {commit} into {src.relative_to(REPO)}")
    archive = subprocess.Popen(["git", "-C", qemu, "archive", commit], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", src], stdin=archive.stdout, check=True)
    if archive.wait() != 0:
        die(f"git archive {commit} failed")
    for entry in (qemu / "subprojects").iterdir():
        dest = src / "subprojects" / entry.name
        if dest.exists():
            continue
        if entry.is_dir():
            shutil.copytree(entry, dest, symlinks=True)
        else:
            shutil.copy2(entry, dest)

    note(f"building {build.parent.relative_to(REPO)}")
    env = dict(os.environ, HOST_QEMU_SRC=str(src), HOST_QEMU_TREE=name)
    if subprocess.run([REPO / "build_host_qemu.sh", "hybrid"], cwd=REPO, env=env).returncode:
        die("the build failed")
    note(f"built; time it with: make bench BENCH_QEMU={build.relative_to(REPO)} BACKEND=...")


# -- run ------------------------------------------------------------------------------------------


def parse_report(stdout):
    """The @ lines a workload printed, as metrics, checks, infos and failures."""
    report = {"metrics": {}, "units": {}, "checks": {}, "info": {}, "failures": []}
    for line in stdout.splitlines():
        if not line.startswith("@"):
            continue
        kind, _, rest = line[1:].partition(" ")
        fields = rest.split()
        if kind == "metric" and len(fields) == 3:
            try:
                report["metrics"][fields[0]] = float(fields[1])
                report["units"][fields[0]] = fields[2]
            except ValueError:
                report["failures"].append(f"unreadable metric: {line}")
        elif kind == "check" and len(fields) >= 2:
            report["checks"][fields[0]] = " ".join(fields[1:])
        elif kind == "info" and fields:
            report["info"][fields[0]] = " ".join(fields[1:])
        elif kind == "fail":
            report["failures"].append(rest)
    return report


def read_results(label):
    path = RESULTS / f"{label}.jsonl"
    if not path.exists():
        return None, []
    header, records = None, []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get("type") == "header":
            header = record
        else:
            records.append(record)
    return header, records


def wait_for_quiet(load):
    """Waits until the host's one-minute load average is below `load`."""
    shown = 0
    while os.getloadavg()[0] >= load:
        if time.time() - shown > 300:
            note(f"waiting for the load average ({os.getloadavg()[0]:.1f}) to fall below {load}")
            shown = time.time()
        time.sleep(15)


def run(args):
    build = Build(args.qemu, args.backend)
    known = workloads()
    chosen = list(known) if not args.workloads else args.workloads.replace(",", " ").split()
    for name in chosen:
        if name not in known:
            die(f"no workload {name}; `bench.py list` names them")

    identity = build.identity()
    identity["disk"] = disk_id()
    label = args.label or default_label(build, identity)
    path = RESULTS / f"{label}.jsonl"
    if args.replace:
        path.unlink(missing_ok=True)
    header, records = read_results(label)
    # A label's rounds must all come from the same build, disk and guest, or their medians mean
    # nothing.
    if header:
        changed = [k for k in identity if header["identity"].get(k) != identity[k]]
        if changed:
            die(
                f"{label} has results from a different {', '.join(changed)}; "
                "choose another --label, or --replace to start it again"
            )
    else:
        RESULTS.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            header = {"type": "header", "label": label, "identity": identity}
            f.write(json.dumps(header) + "\n")
    first_round = max((r["round"] for r in records), default=0) + 1

    note(f"{label}: {build.path.parent.name} on {args.backend}, disk {identity['disk']}")
    if os.getloadavg()[0] > 2 and args.wait_quiet is None:
        print(
            f"bench: the load average is {os.getloadavg()[0]:.1f}; "
            "times from a busy Mac are only rough",
            file=sys.stderr,
        )

    for rnd in range(first_round, first_round + args.rounds):
        if args.wait_quiet is not None:
            wait_for_quiet(args.wait_quiet)
        run_round(build, label, rnd, chosen, path)
    note(f"results in {path.relative_to(REPO)}; compare with: make bench-compare LABELS={label}")


def default_label(build, identity):
    if "fork" in identity:
        return f"{build.backend}-{identity['fork']}"
    return f"{build.backend}-{build.path.parent.name}"


def run_round(build, label, rnd, chosen, results_path):
    run_dir = RUNS / label / f"round-{rnd}"
    shutil.rmtree(run_dir, ignore_errors=True)
    note(f"round {rnd}")
    for name in chosen:
        record = run_workload(build, name, rnd, run_dir)
        with open(results_path, "a") as f:
            f.write(json.dumps(record) + "\n")


def run_workload(build, name, rnd, run_dir):
    """Boots a fresh guest for one workload, runs it, and returns its record.

    A fresh boot and disk each, as one workload's leftovers slow the next: node_compute ran up to
    four times slower after the others, as QEMU discards translations of memory the guest reuses.
    """
    disk = run_dir / f"{name}.qcow"
    clone(DISK, disk)
    try:
        started = time.time()
        with Machine(build, disk, run_dir / name) as m:
            boot = time.time() - started
            m.run(f"mkdir -p {GUEST_DIR}/guest {GUEST_DIR}/workloads")
            for sub in ("guest", "workloads"):
                for f in sorted((HERE / sub).iterdir()):
                    if f.is_file():
                        m.put(f, f"{GUEST_DIR}/{sub}/{f.name}")
            try:
                return measure(m, name, rnd, run_dir, boot)
            except gx.Unreachable as e:
                # A guest that hangs or crashes fails this workload, not the rest of the run.
                print(f"    {name:<16} FAILED: lost the guest: {e}", flush=True)
                return failed_record(name, rnd, f"lost the guest: {e}")
    finally:
        disk.unlink(missing_ok=True)


def failed_record(name, rnd, reason):
    return {
        "type": "result",
        "round": rnd,
        "workload": name,
        "ok": False,
        "metrics": {},
        "units": {},
        "checks": {},
        "info": {},
        "failures": [reason],
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


def measure(m, name, rnd, run_dir, boot):
    """Runs one workload in a booted guest; its log goes beside the machine's, in run_dir/name."""
    load = os.getloadavg()[0]
    start = time.time()
    log = f"{GUEST_DIR}/{name}.log"
    status, stdout, stderr = m.run(
        f"cd /tmp && BENCH_DIR={GUEST_DIR} BENCH_LOG={log} "
        f"sh -c '. {GUEST_DIR}/guest/lib.sh && . {GUEST_DIR}/workloads/{name}.sh'",
        timeout=WORKLOAD_TIMEOUT,
    )
    wall = time.time() - start
    _, guest_log, _ = m.run(f"cat {log} 2>/dev/null")
    (run_dir / name / "workload.log").write_text(
        guest_log + "\n-- stdout --\n" + stdout + "\n-- stderr --\n" + stderr
    )

    report = parse_report(stdout)
    if status != 0 and not report["failures"]:
        report["failures"].append(f"exited with status {status}")
    ok = not report["failures"] and bool(report["metrics"])
    if not report["metrics"] and not report["failures"]:
        report["failures"].append("reported no metrics")

    shown = "  ".join(f"{k} {v:g} {report['units'][k]}" for k, v in report["metrics"].items())
    print(
        f"    {name:<16} {shown if ok else 'FAILED: ' + '; '.join(report['failures'])}", flush=True
    )
    return {
        "type": "result",
        "round": rnd,
        "workload": name,
        "ok": ok,
        "metrics": report["metrics"] if ok else {},
        "units": report["units"],
        "checks": report["checks"],
        "info": report["info"],
        "failures": report["failures"],
        "wall": round(wall, 2),
        "boot": round(boot, 2),
        "load": [round(load, 2), round(os.getloadavg()[0], 2)],
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


# -- compare --------------------------------------------------------------------------------------


def compare(args):
    sets = []
    for label in args.labels:
        header, records = read_results(label)
        if header is None:
            die(f"no results for {label} in {RESULTS.relative_to(REPO)}")
        sets.append((label, header, records))

    disks = {h["identity"].get("disk") for _, h, _ in sets}
    if len(disks) > 1:
        print("bench: these labels ran on different disks; their workloads' programs may differ\n")

    for label, header, records in sets:
        i = header["identity"]
        rounds = len({r["round"] for r in records})
        what = i.get("fork") or i["qemu"]
        print(f"{label}: {what} on {i['backend']}, {rounds} round(s), disk {i.get('disk')}")
    print()

    # Rows in the order the workloads and their metrics first appear.
    rows, units = [], {}
    for _, _, records in sets:
        for r in records:
            for metric in r["metrics"]:
                key = (r["workload"], metric)
                if key not in rows:
                    rows.append(key)
                units[key] = r["units"].get(metric, "")

    def values(records, key):
        w, metric = key
        return [
            r["metrics"][metric] for r in records if r["workload"] == w and metric in r["metrics"]
        ]

    # A cell is the median over the rounds, the spread of the rounds about it, and, after the
    # first label, the median as a multiple of the first label's: below 1.00x is faster.
    width = max([len(f"{w} {m} ({units[(w, m)]})") for w, m in rows] + [8])
    print(f"{'':<{width}}" + "".join(f"{label[:24]:>26}" for label, _, _ in sets))
    for key in rows:
        cells = []
        base = None
        for n, (_, _, records) in enumerate(sets):
            v = values(records, key)
            if not v:
                cells.append(f"{'-':>26}")
                continue
            median = statistics.median(v)
            cell = f"{median:.2f}" if median < 100 else f"{median:.0f}"
            if len(v) > 1 and median:
                cell += f" ±{(max(v) - min(v)) / 2 / median * 100:.0f}%"
            if n == 0:
                base = median
            elif base:
                cell += f" {median / base:5.2f}x"
            cells.append(f"{cell:>26}")
        print(f"{f'{key[0]} {key[1]} ({units[key]})':<{width}}" + "".join(cells))

    # Every successful round of every label should have produced the same output. A failed run's
    # checks may come from partial output, so they are left out.
    print()
    mismatches = 0
    names = []
    for _, _, records in sets:
        for r in records:
            if not r["ok"]:
                continue
            for check in r["checks"]:
                if (r["workload"], check) not in names:
                    names.append((r["workload"], check))
    for w, check in names:
        seen = {}
        for label, _, records in sets:
            for r in records:
                if r["ok"] and r["workload"] == w and check in r["checks"]:
                    seen.setdefault(r["checks"][check], set()).add(label)
        if len(seen) > 1:
            mismatches += 1
            detail = "; ".join(f"{v} from {', '.join(sorted(ls))}" for v, ls in seen.items())
            print(f"MISMATCH {w} {check}: {detail}")
    failed = sum(1 for _, _, records in sets for r in records if not r["ok"])
    print(
        f"checks: {len(names)} compared, {mismatches} mismatched; "
        f"{failed} workload run(s) failed and are left out"
    )


# -- list -----------------------------------------------------------------------------------------


def list_workloads(_):
    known = workloads()
    width = max(map(len, known))
    for name, summary in known.items():
        print(f"{name:<{width}}  {summary}")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("prepare", help="build the benchmark disk (needs the network)")
    p.add_argument("--qemu", default=DEFAULT_QEMU, help="the QEMU to install with, on the JIT")
    p.set_defaults(fn=prepare)

    p = sub.add_parser("baseline", help="build the hybrid QEMU from a fork commit, to compare")
    p.add_argument("commit", help="a commit in third-party/qemu")
    p.add_argument("--name", help="the build's suffix: qemu_hybrid-<name> (default: the commit)")
    p.set_defaults(fn=baseline)

    p = sub.add_parser("run", help="run workloads and record their results")
    p.add_argument("--backend", choices=("tcti", "jit"), required=True)
    p.add_argument("--qemu", default=DEFAULT_QEMU, help="the QEMU to run (default: the hybrid)")
    p.add_argument("--workloads", help="which workloads, comma- or space-separated (default: all)")
    p.add_argument("--rounds", type=int, default=1, help="how many times to run each workload")
    p.add_argument("--label", help="what to record the results as (default: backend and build)")
    p.add_argument(
        "--wait-quiet",
        type=float,
        metavar="LOAD",
        help="before each round, wait until the load average is below LOAD",
    )
    p.add_argument("--replace", action="store_true", help="discard the label's earlier results")
    p.set_defaults(fn=run)

    p = sub.add_parser("compare", help="tabulate labels against the first")
    p.add_argument("labels", nargs="+")
    p.set_defaults(fn=compare)

    p = sub.add_parser("list", help="name the workloads")
    p.set_defaults(fn=list_workloads)

    args = parser.parse_args()
    # A TERM, from timeout(1) or a closing terminal, unwinds like ^C, so QEMU is stopped.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    try:
        args.fn(args)
    except KeyboardInterrupt:
        sys.exit(130)
    except gx.Unreachable as e:
        die(f"lost the guest: {e}")


if __name__ == "__main__":
    main()
