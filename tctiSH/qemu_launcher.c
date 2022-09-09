//
// Low-level QEMU launcher.
// Creates a thread that implements lightweight virtualization atop TCTI.
//
// Thanks to UTM for the jailbreak/ptrace code.
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright (c) 2022 Kate Temkin.
//  Copyright (c) 2020 osy.
//

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>

#include "qemu_launcher.h"

// For early development / test distribution, always produce logs.
#ifndef DEBUG_QEMU
#define DEBUG_QEMU
#endif

#define ARGUMENT_MAX (2048)
#define PATH_MAX     (1024)

// Helpers.
#define ARRAY_SIZE(array) \
    (sizeof(array) / sizeof(array[0]))

// External functionality for JIT hacks.
extern int csops(pid_t pid, unsigned int ops, void * useraddr, size_t usersize);
extern boolean_t exc_server(mach_msg_header_t *, mach_msg_header_t *);
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

#define    CS_OPS_STATUS             0    /* return status */
#define    CS_KILL          0x00000200  /* kill process if it becomes invalid */
#define    CS_DEBUGGED      0x10000000  /* process is currently or has previously been debugged and allowed to run with invalid pages */
#define    PT_TRACE_ME               0       /* child declares it's being traced */
#define    PT_SIGEXC                12      /* signals as exceptions for current_proc */


//
// QEMU internals that we'll use.
//
typedef void (*qemu_init_fn)(int argc, const char *argv[], const char *envp[]);
typedef void (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(void);

// Structure for passing arguments to our QEMU thread.
struct qemu_args {
    char *qemu_image;
    char *bios_dir;
    char *kernel_filename;
    char *initrd_filename;
    char *disk_args;
    char *snapshot_name;
    char *dll_name;
    bool is_jit;
    
#ifdef DEBUG_QEMU
    char *log_file;
#endif
    
};

/// Core thread that runs our background QEMU.
static void* qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;

    void *qemu_dll;
    qemu_init_fn qemu_init;
    qemu_main_loop_fn qemu_main_loop;
    qemu_cleanup_fn qemu_cleanup;

    // Provide our QEMU command line and environment...
    char *envp[] = { NULL };
    char *argv[] = {
        "qemu-system",
        
        // Tell QEMU where any option ROMS it might want are hiding.
        "-L", args->bios_dir,
        
        // We're a terminal; we don't display anything.
        "-display", "none",
        
        // Guest memory.
        "-m", "1G",
        
#ifdef DEBUG_QEMU
        // Write to a local log.
        "-D", args->log_file,
#endif
        
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

        // Provide a few cores.
        "-smp", "cpus=4",
        
        // Monitor conection for tctiSH.
        "-monitor", "tcp:localhost:10044,server,wait=off",
        
        // Monitor conection in-guest tools.
        "-monitor", "tcp:localhost:10045,server,wait=off",

        // Use JIT if we have JIT hacks,
        "-accel", args->is_jit ? "tcg,split-wx=on" : "tcg",
        
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

    // Open the appropriate QEMU framework...
    qemu_dll = dlopen(args->qemu_image, RTLD_NOW);

    // ... and fetch the QEMU functions we need.
    qemu_init = dlsym(qemu_dll, "qemu_init");
    qemu_main_loop = dlsym(qemu_dll, "qemu_main_loop");
    qemu_cleanup = dlsym(qemu_dll, "qemu_cleanup");

    // Finally, run the lightweight VM.
    qemu_init(argc, (const char **)argv, (const char **)envp);
    qemu_main_loop();
    qemu_cleanup();
    
    // Clean up the memory allcoated for this thread.
    free(args->bios_dir);
    free(args->kernel_filename);
    free(args->initrd_filename);
    free(args->disk_args);
    free(args->log_file);
    free(args);
    
    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(const char* qemu_path,
                         const char* kernel_path,
                         const char* initrd_path,
                         const char* bios_path,
                         const char* disk_path,
                         const char* snapshot_name,
                         const char* log_file_path,
                         bool is_jit)
{
    pthread_t thread;
    pthread_attr_t qosAttribute;
    
    struct qemu_args *args = calloc(1, sizeof(struct qemu_args));

    args->is_jit           = is_jit;
    args->qemu_image       = calloc(PATH_MAX, sizeof(char));
    args->kernel_filename  = calloc(PATH_MAX, sizeof(char));
    args->initrd_filename  = calloc(PATH_MAX, sizeof(char));
    args->bios_dir         = calloc(PATH_MAX, sizeof(char));
    args->log_file         = calloc(PATH_MAX, sizeof(char));
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
    strncpy(args->qemu_image, qemu_path, PATH_MAX - 1);
    strncpy(args->kernel_filename, kernel_path, PATH_MAX - 1);
    strncpy(args->initrd_filename, initrd_path, PATH_MAX - 1);
    strncpy(args->log_file, log_file_path, PATH_MAX - 1);
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

/// Returns true iff the process has a debugger attached.
/// (Method from UTM.)
static bool has_debugger_attached(void) {
    int flags;
    return !csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) && flags & CS_DEBUGGED;
}

/// Exception passthrough for our debug hack.
/// (Method from UTM.)
static void *exception_handler(void *argument) {
    mach_port_t port = *(mach_port_t *)argument;
    mach_msg_server(exc_server, 2048, port, 0);
    return NULL;
}


/// Attempts to enable JIT via a ptrace-based debugger.
/// (Method from UTM.)
static bool enable_ptrace_hack(void) {
    bool debugged = has_debugger_attached();

    // Thanks to this comment: https://news.ycombinator.com/item?id=18431524
    // We use this hack to allow mmap with PROT_EXEC (which usually requires the
    // dynamic-codesigning entitlement) by tricking the process into thinking
    // that Xcode is debugging it. We abuse the fact that JIT is needed to
    // debug the process.
    if (ptrace(PT_TRACE_ME, 0, NULL, 0) < 0) {
        return false;
    }

    // ptracing ourselves confuses the kernel and will cause bad things to
    // happen to the system (hangs…) if an exception or signal occurs. Setup
    // some "safety nets" so we can cause the process to exit in a somewhat sane
    // state. We only need to do this if the debugger isn't attached. (It'll do
    // this itself, and if we do it we'll interfere with its normal operation
    // anyways.)
    if (!debugged) {
        // First, ensure that signals are delivered as Mach software exceptions…
        ptrace(PT_SIGEXC, 0, NULL, 0);

        // …then ensure that this exception goes through our exception handler.
        // I think it's OK to just watch for EXC_SOFTWARE because the other
        // exceptions (e.g. EXC_BAD_ACCESS, EXC_BAD_INSTRUCTION, and friends)
        // will end up being delivered as signals anyways, and we can get them
        // once they're resent as a software exception.
        mach_port_t port = MACH_PORT_NULL;
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        task_set_exception_ports(mach_task_self(), EXC_MASK_SOFTWARE, port, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        pthread_t thread;
        pthread_create(&thread, NULL, exception_handler, (void *)&port);
    }

    return true;
}

bool set_up_jit(void) {
    // For now, we only have one JIT method, but later we should support
    // some e.g. jailbreak based methods.
    return enable_ptrace_hack();
}
