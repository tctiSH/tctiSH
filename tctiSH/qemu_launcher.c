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

//
// QEMU internals that we'll use.
//
void qemu_init(int argc, const char *argv[], const char *envp[]);
void qemu_main_loop(void);
void qemu_cleanup(void);

// Structure for passing arguments to our QEMU thread.
struct qemu_args {
    char *bios_dir;
    char *kernel_filename;
    char *initrd_filename;
    char *disk_args;
    char *snapshot_name;
};

/// Core thread that runs our background QEMU.
static void* qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;
    
    // Provide our QEMU command line and environment...
    char *envp[] = { NULL };
    char *argv[] = {
        "qemu-system",
        
        // Tell QEMU where any option ROMS it might want areh hiding.
        "-L", args->bios_dir,
        
        // We're a terminal; we don't display anything.
        "-display", "none",
        
        // Guest memory.
        "-m", "1G",
        
        // Networking.
        "-device", "virtio-net-pci,id=net1,netdev=net0",
        "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp::10022-:22",
        
        // Provide our host RNG to our guest; to speed up entropy generation.
        "-device", "virtio-rng-pci",
        
        // Provide the disk we'll be working with.
        "-device", "virtio-blk-pci,id=disk1,drive=drive1",
        "-drive", args->disk_args,
        
        // Select our kernel and ramdisk.
        "-kernel", args->kernel_filename,
        "-initrd", args->initrd_filename,
        
        // Kernel command line; tells our image how to handle disk images.
        // This variant selects the provided qcow disk file.
        "-append", "tcti_disk=file",
        
        // Monitor conection for tctiSH.
        "-monitor", "tcp:localhost:10044,server,wait=off",
        
        // Monitor conection in-guest tools.
        "-monitor", "tcp:localhost:10045,server,wait=off",
        
        // Resume from our instant boot cache, if possible.
        "-loadvm", args->snapshot_name,
    };
    
    // Compute the number of arguments.
    int argc = ARRAY_SIZE(argv);
    
    // If we don't have a snapshot, remove those arguments.
    // (This is a "recovery boot").
    if (!args->snapshot_name) {
        argc -= 2;
    }
    
    // Finally, run the lightweight VM.
    qemu_init(argc, (const char **)argv, (const char **)envp);
    qemu_main_loop();
    qemu_cleanup();
    
    // Clean up the memory allcoated for this thread.
    free(args->bios_dir);
    free(args->kernel_filename);
    free(args->initrd_filename);
    free(args->disk_args);
    free(args);
    
    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(const char* kernel_path,
                         const char* initrd_path,
                         const char* bios_path,
                         const char* disk_path,
                         const char* snapshot_name)
{
    pthread_t thread;
    pthread_attr_t qosAttribute;
    
    struct qemu_args *args = calloc(1, sizeof(struct qemu_args));
    
    args->kernel_filename  = calloc(PATH_MAX, sizeof(char));
    args->initrd_filename  = calloc(PATH_MAX, sizeof(char));
    args->bios_dir         = calloc(PATH_MAX, sizeof(char));
    if (snapshot_name) {
        args->snapshot_name = calloc(PATH_MAX, sizeof(char));
    } else {
        args->snapshot_name = NULL;
    }
    
    // Create our disk argument.
    args->disk_args         = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->disk_args, ARGUMENT_MAX, "media=disk,id=drive1,if=none,file=%s,discard=unmap,detect-zeroes=unmap",
             disk_path);
    
    // Copy in each of our filenames.
    strncpy(args->kernel_filename, kernel_path, PATH_MAX - 1);
    strncpy(args->initrd_filename, initrd_path, PATH_MAX - 1);
    strncpy(args->bios_dir, bios_path, PATH_MAX - 1);
    if (args->snapshot_name) {
        strncpy(args->snapshot_name, snapshot_name, PATH_MAX - 1);
    }
    
    // Finally, spawn our thread.
    pthread_attr_init(&qosAttribute);
    pthread_attr_set_qos_class_np(&qosAttribute, QOS_CLASS_USER_INTERACTIVE, 0);

    pthread_create(&thread, &qosAttribute, qemu_thread, args);
    pthread_detach(thread);
}
