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

/// Runs QEMU in a background thread, providing our shell.
void run_background_qemu(const char *qemu_path,
                         const char *kernel_path,
                         const char *initrd_path,
                         const char *bios_path,
                         const char *disk_path,
                         const char *shared_folder_path,
                         const char *boot_image_name,
                         const char *memory_value,
                         const char *monitor_socket_path,
                         bool is_jit,
                         bool bless_jit_regions);

#endif /* qemu_launcher_h */
