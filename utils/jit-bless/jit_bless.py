"""LLDB support for tctiSH's iOS 26+ JIT breakpoint protocol.

On iOS 26 and later, TXM prevents a process from making its own JIT mappings
executable. QEMU therefore hands each executable region to whatever debugger is
attached, by trapping with the region's address in x0 and its length in x1:

    mov x0, addr ; mov x1, len ; brk #0x69

The debugger is expected to write one byte into each page of the region (the
write travels the kernel's debug path, which is what makes the page usable) then
step past the trap and continue. StikJIT's `legacy.js` does exactly this over
the gdb-remote protocol; this script does the same thing from LLDB, so the JIT
path can be exercised under Xcode without a StikJIT helper in the loop.

Importing the module arms a stop hook that answers the trap automatically, so
the whole of the installation is one line in ~/.lldbinit-Xcode:

    command script import /path/to/jit_bless.py

That file is read by *every* Xcode debugging session on the machine, so the hook
scopes itself to the JIT framework. LLDB matches the module itself, before it
enters Python, which is what keeps this inert in other projects: no handler
runs, nothing is printed, and no log file appears. The import is likewise silent
unless it fails.

To handle a single trap by hand, once stopped on it:

    (lldb) jit-bless

The byte written is 0x69 purely to echo the breakpoint immediate; its value is
irrelevant, as QEMU overwrites the whole buffer with generated code immediately
afterwards.
"""

import datetime
import os
import time

import lldb

#: Breakpoint immediate QEMU uses to request a region. Matches `legacy.js`.
BRK_IMMEDIATE = 0x69

#: Module the trap is raised from -- `break_prepare_jit_region()` is ordinary
#: compiled code inside the JIT build of QEMU, so the pc at the stop is always
#: in this binary. Scoping the stop hook to it is what confines this script to
#: tctiSH; the TCTI build (`qemu-x86_64-softmmu`) never traps.
JIT_MODULE = "qemu-x86_64-softmmu_jit"

#: Stop reasons a `brk` can plausibly arrive as. Filtering on this first spares
#: a memory read on every step taken while debugging QEMU itself.
TRAP_STOP_REASONS = (
    lldb.eStopReasonException,
    lldb.eStopReasonBreakpoint,
    lldb.eStopReasonSignal,
)

#: Page size the region is blessed at. iOS is 16K, and StikJIT blesses per page.
JIT_PAGE_SIZE = 16384

#: AArch64 BRK #imm16 is 0xD4200000 | (imm16 << 5); these mask off the immediate.
BRK_OPCODE_MASK = 0xFFE0001F
BRK_OPCODE = 0xD4200000

#: Roughly how many progress lines to emit, whatever the region's size.
#:
#: A fixed interval doesn't scale: 256 was eight lines for the 32 MiB region this
#: was written against, and would be two thousand for an 8 GiB one.
PROGRESS_UPDATES = 12

#: Xcode renders its own stop UI and swallows stop-hook output, so everything is
#: also written here. The script runs on the host, so this is just a local file.
LOG_PATH = os.environ.get("JIT_BLESS_LOG", "/tmp/jit-bless.log")


def log_to_file(message):
    """Appends a timestamped line to LOG_PATH, ignoring any failure to do so."""
    try:
        stamp = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        with open(LOG_PATH, "a") as handle:
            handle.write("%s %s\n" % (stamp, message))
    except OSError:
        pass


def make_logger(emit):
    """Wraps an output function so everything it prints is also recorded."""

    def log(message):
        log_to_file(message)
        emit(message)

    return log


def decode_brk_immediate(instruction):
    """Returns the immediate of an AArch64 BRK, or None if it isn't one."""
    if (instruction & BRK_OPCODE_MASK) != BRK_OPCODE:
        return None
    return (instruction >> 5) & 0xFFFF


def read_instruction(process, address):
    """Reads the 32-bit instruction at `address`, or None if unreadable."""
    error = lldb.SBError()
    data = process.ReadMemory(address, 4, error)
    if not error.Success() or data is None or len(data) != 4:
        return None
    return int.from_bytes(data, "little")


def pending_region(frame, process):
    """If the frame is stopped at our trap, returns (address, length, pc).

    Returns None for any other stop, so user breakpoints are left alone.
    """
    pc = frame.GetPC()
    instruction = read_instruction(process, pc)
    if instruction is None:
        return None

    if decode_brk_immediate(instruction) != BRK_IMMEDIATE:
        return None

    address = frame.FindRegister("x0").GetValueAsUnsigned()
    length = frame.FindRegister("x1").GetValueAsUnsigned()
    return (address, length, pc)


def bless_region(process, address, length, log):
    """Writes one byte into each page of [address, address + length).

    Returns True if every page was written.
    """
    if length == 0:
        log("jit-bless: zero-length region; nothing to do")
        return True

    pages = (length - 1) // JIT_PAGE_SIZE + 1
    log(
        "jit-bless: blessing 0x%x + 0x%x (%d pages of %dK)"
        % (address, length, pages, JIT_PAGE_SIZE // 1024)
    )

    started = time.monotonic()
    interval = max(pages // PROGRESS_UPDATES, 1)
    error = lldb.SBError()

    for page in range(pages):
        page_address = address + page * JIT_PAGE_SIZE
        written = process.WriteMemory(page_address, bytes([BRK_IMMEDIATE]), error)

        if not error.Success() or written != 1:
            log(
                "jit-bless: FAILED writing page %d at 0x%x: %s"
                % (page, page_address, error.GetCString())
            )
            return False

        if page and page % interval == 0:
            elapsed = time.monotonic() - started
            log(
                "jit-bless:   %d/%d pages (%.0fs elapsed, ~%.0fs left)"
                % (page, pages, elapsed, elapsed * (pages - page) / page)
            )

    log("jit-bless: blessed %d pages in %.1fs" % (pages, time.monotonic() - started))
    return True


def step_over_trap(frame, pc, log):
    """Advances past the BRK so the process doesn't re-trap on continue."""
    if not frame.SetPC(pc + 4):
        log("jit-bless: FAILED to advance pc past the trap at 0x%x" % pc)
        return False
    return True


def handle_trap(frame, process, log):
    """Blesses the pending region and steps past the trap.

    Returns True if this was our trap and it was handled.
    """
    region = pending_region(frame, process)
    if region is None:
        return False

    address, length, pc = region
    if not bless_region(process, address, length, log):
        return False

    return step_over_trap(frame, pc, log)


def jit_bless_command(debugger, command, exe_ctx, result, internal_dict):
    """`jit-bless` -- handle the trap the process is currently stopped at.

    Continues afterwards unless `stay` is passed.
    """
    log = make_logger(lambda message: print(message, file=result))

    process = exe_ctx.GetProcess()
    frame = exe_ctx.GetFrame()

    if not process.IsValid() or not frame.IsValid():
        result.SetError("jit-bless: no running process")
        return

    if pending_region(frame, process) is None:
        result.SetError(
            "jit-bless: not stopped at a brk #0x%x -- pc is 0x%x" % (BRK_IMMEDIATE, frame.GetPC())
        )
        return

    if not handle_trap(frame, process, log):
        result.SetError("jit-bless: failed to bless the region; see above")
        return

    if command.strip() == "stay":
        log("jit-bless: done; process left stopped")
        return

    log("jit-bless: done; continuing")
    process.Continue()


class BlessStopHook:
    """Stop hook that blesses regions automatically as they are requested.

    Stops normally for anything that isn't our trap, so ordinary debugging is
    unaffected.
    """

    def __init__(self, target, extra_args, internal_dict):
        self.target = target

    def handle_stop(self, exe_ctx, stream):
        log = make_logger(lambda message: stream.Print(message + "\n"))

        process = exe_ctx.GetProcess()
        frame = exe_ctx.GetFrame()

        if not process.IsValid() or not frame.IsValid():
            return True

        if frame.GetThread().GetStopReason() not in TRAP_STOP_REASONS:
            return True

        if pending_region(frame, process) is None:
            # Not ours -- let the stop happen as usual.
            return True

        if not handle_trap(frame, process, log):
            log("jit-bless: leaving the process stopped for inspection")
            return True

        # False means "resume"; the region is ready and the pc is past the trap.
        return False


def run_quietly(debugger, command):
    """Runs an LLDB command without letting it print to the console.

    Returns its output, or None if it failed.
    """
    result = lldb.SBCommandReturnObject()
    debugger.GetCommandInterpreter().HandleCommand(command, result)
    if not result.Succeeded():
        return None
    return result.GetOutput() or ""


def already_armed(debugger):
    """True if this debugger already has one of our stop hooks.

    Asks LLDB rather than remembering, because `command script import` reloads
    the module -- so module-level state resets, while a hook added by the
    previous import is still there. Importing twice would otherwise bless every
    region twice.
    """
    hooks = run_quietly(debugger, "target stop-hook list")
    return hooks is not None and "%s.BlessStopHook" % __name__ in hooks


def arm_stop_hook(debugger):
    """Registers BlessStopHook against the JIT framework, at most once."""
    if already_armed(debugger):
        return True

    return (
        run_quietly(
            debugger, "target stop-hook add -P %s.BlessStopHook -s %s" % (__name__, JIT_MODULE)
        )
        is not None
    )


def __lldb_init_module(debugger, internal_dict):
    run_quietly(debugger, "command script add -f %s.jit_bless_command -o jit-bless" % __name__)

    # Speak only when something is wrong. This module is imported from
    # ~/.lldbinit-Xcode, so anything printed here lands in the console of every
    # project on the machine, and anything logged creates LOG_PATH for them too.
    if not arm_stop_hook(debugger):
        print(
            "jit-bless: could not register the stop hook; brk #0x%x will halt "
            "the process instead of being answered" % BRK_IMMEDIATE
        )
