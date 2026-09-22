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
/// of it at once. Only an iOS JIT build can honour it -- it exists to spread the
/// cost of handing pages to a debugger -- and QEMU ignores it where there is no
/// blessing to spread.
void run_background_qemu(const char *qemu_path, const char *kernel_path, const char *initrd_path,
                         const char *bios_path, const char *disk_path,
                         const char *shared_folder_path, const char *boot_image_name,
                         const char *memory_value, const char *monitor_socket_path, bool is_jit,
                         bool bless_jit_regions, unsigned int tb_size_mib, unsigned int chunk_mib);

/// The running VM's code cache, in bytes. All report 0 before QEMU is up.
///
/// These reach into the QEMU image the VM thread opened, rather than being
/// linked against: there are two of them, only one is loaded, and which one it
/// is isn't known until JIT has been settled.
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

#endif /* qemu_launcher_h */
