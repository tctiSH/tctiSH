//
//  qemu_launcher.c
//  tctiSH
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright © 2022 Kate Temkin. All rights reserved.
//

#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>

#include "qemu_launcher.h"

// Helpers.
#define ARRAY_SIZE(array) \
    (sizeof(array) / sizeof(array[0]))

// QEMU internals that we'll use.
int qemu_init(int argc, const char *argv[], const char *envp[]);
void qemu_main_loop(void);
void qemu_cleanup(void);


// Structure for passing arguments to QEMU.
struct qemu_args {
    int argc;
    const char **argv;
    const char **envp;
};


/// Core thread that runs our background QEMU.
static void* qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;

    qemu_init(args->argc, args->argv, args->envp);
    qemu_main_loop();
    qemu_cleanup();
    
    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(const char* kernel_path, const char* initrd_path, const char* bios_path) {
    
    //char disk_argument[2048];
    
    // Create our disk argument.
    /*
    snprintf(disk_argument, sizeof(disk_argument), "media=disk,id=drive1,if=none,file=%s,discard=unmap,detect-zeroes=unmap",
             disk_path);
     */
    
    pthread_t thread;
    pthread_attr_t qosAttribute;
    
    static struct qemu_args args;
    
    static char kernel_filename[1024];
    static char initrd_filename[1024];
    static char bios_dir[1024];
    
    strncpy(kernel_filename, kernel_path, sizeof(kernel_filename));
    strncpy(initrd_filename, initrd_path, sizeof(initrd_filename));
    strncpy(bios_dir, bios_path, sizeof(bios_dir));
    kernel_filename[1023] = '\0';
    initrd_filename[1023] = '\0';
    bios_dir[1023] = '\0';
    
    // Provide our QEMU command line and environment.
    static char *envp[] = { NULL };
    static char *argv[] = {
        "qemu-system",
        "-L", bios_dir,
        "-display", "none",
        "-kernel", kernel_filename,
        "-initrd", initrd_filename,
        "-m", "4G",
        "-device", "virtio-net-pci,id=net1,netdev=net0",
        "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22,hostfwd=tcp::10023-:23",
        "-device", "virtio-rng-pci",
        //"-device", "virtio-blk-pci,id=disk1,drive=drive1",
        //"-drive", disk_argument,
        //"-append", "tcti_disk=file",
    };
    
    args.argc = ARRAY_SIZE(argv);
    args.argv = (const char**) argv;
    args.envp = (const char**) envp;
    
    pthread_attr_init(&qosAttribute);
    pthread_attr_set_qos_class_np(&qosAttribute, QOS_CLASS_USER_INTERACTIVE, 0);

    pthread_create(&thread, &qosAttribute, qemu_thread, &args);
    pthread_detach(thread);
}
