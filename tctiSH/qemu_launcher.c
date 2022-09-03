//
// Low-level QEMU launcher.
// Creates a thread that implements lightweight virtualization atop TCTI.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright (c) 2022 Kate Temkin.
//

#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>

#include "qemu_launcher.h"

#define ARGUMENT_MAX (2048)
#define PATH_MAX     (1024)

// Helpers.
#define ARRAY_SIZE(array) \
    (sizeof(array) / sizeof(array[0]))

// QEMU internals that we'll use.
int qemu_init(int argc, const char *argv[], const char *envp[]);
void qemu_main_loop(void);
void qemu_cleanup(void);

// Structure for passing arguments to our QEMU thread.
struct qemu_args {
    char *bios_dir;
    char *kernel_filename;
    char *initrd_filename;
    char *memstate_args;
};


/// Core thread that runs our background QEMU.
static void* qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;
    
    // Provide our QEMU command line and environment...
    char *envp[] = { NULL };
    char *argv[] = {
        "qemu-system",
        "-L", args->bios_dir,
        "-display", "none",
        "-kernel", args->kernel_filename,
        "-initrd", args->initrd_filename,
        "-m", "1G",
        "-device", "virtio-net-pci,id=net1,netdev=net0",
        "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22",
        "-device", "virtio-rng-pci",
        args->memstate_args ? "-drive" : "",
        args->memstate_args ? args->memstate_args : "",
        args->memstate_args ? "-loadvm" : "",
        args->memstate_args ? "nodisk" : "",
        //"-device", "virtio-blk-pci,id=disk1,drive=drive1",
        //"-drive", disk_argument,
        //"-append", "tcti_disk=file",
    };

    // ... and run QEMU, in this thread.
    qemu_init(ARRAY_SIZE(argv), (const char **)argv, (const char **)envp);
    qemu_main_loop();
    qemu_cleanup();
    
    // Clean up the memory allcoated for this process.
    free(args->bios_dir);
    free(args->kernel_filename);
    free(args->initrd_filename);
    if (args->memstate_args) {
        free(args->memstate_args);
    }
    free(args);
    
    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(
                         const char* kernel_path,
                         const char* initrd_path,
                         const char* bios_path,
                         const char* memstate_path)
{
    pthread_t thread;
    pthread_attr_t qosAttribute;
    
    struct qemu_args *args = calloc(1, sizeof(struct qemu_args));
    
    args->kernel_filename  = calloc(PATH_MAX, sizeof(char));
    args->initrd_filename  = calloc(PATH_MAX, sizeof(char));
    args->bios_dir         = calloc(PATH_MAX, sizeof(char));
    
    // Create our "instant-boot" argument.
    if (memstate_path) {
        args->memstate_args = calloc(ARGUMENT_MAX, sizeof(char));
        snprintf(args->memstate_args, ARGUMENT_MAX, "media=disk,id=memstate,if=none,file=%s",
                 memstate_path);
    } else {
        args->memstate_args = NULL;
    }
    
    // Copy in each of our filenames.
    strncpy(args->kernel_filename, kernel_path, PATH_MAX - 1);
    strncpy(args->initrd_filename, initrd_path, PATH_MAX - 1);
    strncpy(args->bios_dir, bios_path, PATH_MAX - 1);
    
    // Finally, spawn our thread.
    pthread_attr_init(&qosAttribute);
    pthread_attr_set_qos_class_np(&qosAttribute, QOS_CLASS_USER_INTERACTIVE, 0);

    pthread_create(&thread, &qosAttribute, qemu_thread, args);
    pthread_detach(thread);
}
