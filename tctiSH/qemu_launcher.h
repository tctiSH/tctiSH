//
//  qemu_launcher.h
//  tctiSH
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright © 2022 Kate Temkin. All rights reserved.
//

#ifndef qemu_launcher_h
#define qemu_launcher_h

void run_background_qemu(const char *kernel_path,
                         const char *initrd_path,
                         const char *bios_path,
                         const char *memstate_path);

#endif /* qemu_launcher_h */
