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

/// Runs QEMU in a background thread, providing our shell.
void run_background_qemu(const char *qemu_path,
                         const char *kernel_path,
                         const char *initrd_path,
                         const char *bios_path,
                         const char *disk_path,
                         const char *shared_folder_path,
                         const char *boot_image_name,
                         bool is_jit);

#endif /* qemu_launcher_h */
