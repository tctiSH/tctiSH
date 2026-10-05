//
//  qemu_launcher.h
//  Code for launching QEMU.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright © 2022 Kate Temkin.
//

#ifndef qemu_launcher_h
#define qemu_launcher_h

#include <stdbool.h>
#include <stddef.h>

/// Sets up an environment where we can JIT.
bool set_up_jit(void);

/// Returns true iff a debugger is attached to this process right now.
///
/// The same `P_TRACED` test QEMU makes before raising its blessing trap, so the
/// app can wait for StikJIT's attach to land before starting QEMU. Booting too
/// early doesn't fail loudly; it produces an unblessed JIT region.
bool jit_debugger_tracing(void);

/// Returns true iff this process may make its own mappings executable.
///
/// `CS_DEBUGGED`, which is sticky and survives a detach -- so this answers "is
/// JIT permitted", not "is a debugger here now". Use `jit_debugger_tracing()`
/// for the latter.
bool jit_may_map_executable(void);

/// A stable description of the machine QEMU is told to build.
///
/// The devices, the topology and the guest command line but nothing that
/// varies between installs or between launches, so no paths, no sizes and not
/// the snapshot tag.
///
/// Derived from the same list the command line is built from, so adding a device
/// or changing the topology changes this automatically. That matters because a
/// snapshot is only loadable into the machine it was taken from; see
/// `VmSnapshots` on the Swift side, which digests this to decide whether a saved
/// session can still be resumed.
const char *qemu_machine_signature(void);

/// Runs QEMU in a background thread, providing our shell.
///
/// `tb_size_mib` is the TCG code cache size in MiB, or 0 to let QEMU size the
/// buffer itself with its own heuristic. tctiSH always names a size, because it
/// maps the largest cache it offers however small a one was chosen and enforces
/// the choice itself; see `CodeCache.allocationSize`.
///
/// `chunk_mib` is how much of that cache to make usable at a time, or 0 for all
/// of it at once. Only native code on iOS honors it, and QEMU ignores it where
/// there is no blessing to spread.
///
/// `start_native` picks the backend QEMU starts on: native code, or TCTI. The
/// other can be switched to while the VM runs; see `qemu_backend_switch`.
/// `bless_jit_regions` says whether native code's buffer is handed to a
/// debugger, whichever backend the VM starts on, since it is read whenever that
/// buffer is mapped.
void run_background_qemu(const char *qemu_path, const char *kernel_path, const char *initrd_path,
                         const char *bios_path, const char *disk_path,
                         const char *shared_folder_path, const char *boot_image_name,
                         const char *memory_value, const char *monitor_socket_path,
                         bool start_native, bool bless_jit_regions, unsigned int tb_size_mib,
                         unsigned int chunk_mib);

/// The running VM's code cache, in bytes. All report 0 before QEMU is up.
///
/// These reach into the QEMU image the VM thread opened, rather than being
/// linked against: it is dlopened when the VM starts, not when the app does.
size_t qemu_code_cache_used(void);
size_t qemu_code_cache_usable(void);
size_t qemu_code_cache_total(void);

/// Whether any of the cache is still waiting to be brought into use.
bool qemu_code_cache_can_grow(void);

/// Whether growing needs a debugger attached first.
///
/// False under TCTI, where nothing is executed directly and so nothing has to be
/// prepared: growing there is arithmetic, with no helper and no freeze.
bool qemu_code_cache_needs_debugger(void);

/// Brings the cache into use up to `target` bytes, returning the new usable
/// size, or 0 if nothing changed.
///
/// **A debugger must already be attached**, and must have had time to arm
/// itself: this traps into it, and a trap nobody is listening for is fatal.
/// Every thread in the process stops for as long as the preparation takes.
size_t qemu_code_cache_grow(size_t target);

/// Reduces the cache to `target` bytes, returning what is usable afterwards, or
/// 0 if nothing changed.
///
/// Needs no debugger and causes no freeze as it gives memory up rather than
/// taking it. The memory itself returns at the VM's next flush of translated
/// code, which this asks for; the cap comes down at once.
size_t qemu_code_cache_shrink(size_t target);

/// Hands the whole cache back at the VM's next flush, all but the prologue,
/// and returns whether that was arranged.
///
/// Only for a parked VM: it can't run until `qemu_code_cache_grow` has
/// prepared the cache again, and under TXM it would crash if it did, so QEMU
/// refuses to start it meanwhile. The flush runs even though the VM is stopped;
/// `qemu_code_cache_release_all_outstanding` goes false once it has.
bool qemu_code_cache_release_all(void);

/// Whether a `qemu_code_cache_release_all` is still waiting for its flush.
bool qemu_code_cache_release_all_outstanding(void);

/// Whether a release of everything has left the cache to be prepared again
/// with `qemu_code_cache_grow` before the VM may run.
bool qemu_code_cache_needs_preparing(void);

/// Whether the snapshot the VM was told to resume from turned out not to exist.
///
/// False until QEMU has got far enough to look, so a caller watching for it has
/// to keep asking rather than reading it once.
bool qemu_snapshot_was_missing(void);

/// How many bytes the VM handed back to the system at its last release, or 0 if
/// it could not.
///
/// The only way to find out from outside a debugger session: QEMU says so on
/// stderr, and nothing here captures that.
size_t qemu_code_cache_released(void);

/// How many times the VM has tried to hand memory back, and why the last try
/// failed. Together these tell "was refused" apart from "hasn't happened yet".
size_t qemu_code_cache_release_attempts(void);
int qemu_code_cache_release_errno(void);
int qemu_code_cache_release_errno_rx(void);

/// Which backend the running VM is on: 1 for TCTI, 0 for native code, or -1
/// before QEMU is up.
int qemu_backend_current(void);

/// Maps native code's buffer while the VM runs on TCTI, ahead of a switch to
/// it: 1 if it did, 2 if there was nothing to do, 0 if it could not.
///
/// **Under TXM a debugger must already be attached** and armed, exactly as for
/// `qemu_code_cache_grow`: this traps into it to prepare the buffer, and every
/// thread in the process stops while it does.
int qemu_backend_prepare_native(void);

/// Whether native code's buffer is mapped and prepared, so that a switch to
/// native code needs no debugger.
bool qemu_backend_native_ready(void);

/// Gives native code's buffer back while the VM runs on TCTI. The next switch
/// to native code then maps and prepares it again, which under TXM needs the
/// debugger. Returns whether it was given back, or there was nothing to give.
bool qemu_backend_release_native(void);

/// Asks for a switch to TCTI (`tcti`) or to native code, and returns whether
/// the request was taken. The switch happens in QEMU's own time, normally
/// milliseconds; it is over once `qemu_backend_switches` has moved, and
/// `qemu_backend_current` then says where the VM is.
///
/// A switch to native code needs native code's buffer prepared, and prepares it
/// itself if `qemu_backend_prepare_native` has not -- under TXM, by trapping
/// into the debugger with every vCPU stopped. Prepare first.
bool qemu_backend_switch(bool tcti);

/// How many switches have settled, whether or not they succeeded.
size_t qemu_backend_switches(void);

/// Why the last preparation or switch failed, or NULL. The caller frees it.
char *qemu_backend_last_error(void);

#endif /* qemu_launcher_h */
