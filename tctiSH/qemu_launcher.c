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
#include <stdatomic.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <sys/fcntl.h>
#include <sys/sysctl.h>
#include <sys/_types/_caddr_t.h>

#include "qemu_launcher.h"

// PATH_MAX comes from <limits.h>, and is 1024 on Darwin.
#define ARGUMENT_MAX (2048)

// Helpers.
#define ARRAY_SIZE(array) (sizeof(array) / sizeof(array[0]))

// External functionality for JIT hacks.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern boolean_t exc_server(mach_msg_header_t *, mach_msg_header_t *);
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

#define CS_OPS_STATUS 0          /* return status */
#define CS_KILL       0x00000200 /* kill process if it becomes invalid */
/* process is currently or has previously been debugged and allowed to run with invalid pages */
#define CS_DEBUGGED 0x10000000
#define PT_TRACE_ME 0  /* child declares it's being traced */
#define PT_SIGEXC   12 /* signals as exceptions for current_proc */

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
    char *shared_folder_args;
    char *monitor_channel_args;
    char *boot_image_name;
    char *dll_name;
    char *memory_value;
    char *accel_args;
    bool is_jit;
};

/// The QEMU image, once the VM thread has opened it.
///
/// `dlopen` here is RTLD_LOCAL, so these symbols never reach the global
/// namespace and `RTLD_DEFAULT` cannot find them. Keeping the handle is how
/// anything outside that thread gets to ask QEMU a question.
static _Atomic(void *) qemu_image_handle;

/// Looks a symbol up in the QEMU image, or NULL if it isn't open yet.
static void *qemu_symbol(const char *name) {
    void *handle = atomic_load(&qemu_image_handle);
    return handle ? dlsym(handle, name) : NULL;
}

size_t qemu_code_cache_used(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_used");
    }
    return fn ? fn() : 0;
}

size_t qemu_code_cache_usable(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_usable");
    }
    return fn ? fn() : 0;
}

size_t qemu_code_cache_total(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_total");
    }
    return fn ? fn() : 0;
}

bool qemu_code_cache_can_grow(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_can_grow");
    }
    return fn ? fn() : false;
}

size_t qemu_code_cache_released(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_released");
    }
    return fn ? fn() : 0;
}

size_t qemu_code_cache_release_attempts(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_release_attempts");
    }
    return fn ? fn() : 0;
}

int qemu_code_cache_release_errno(void) {
    static int (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_release_errno");
    }
    return fn ? fn() : 0;
}

int qemu_code_cache_release_errno_rx(void) {
    static int (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_release_errno_rx");
    }
    return fn ? fn() : 0;
}

bool qemu_snapshot_was_missing(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_snapshot_was_missing");
    }
    return fn ? fn() : false;
}

size_t qemu_code_cache_shrink(size_t target) {
    static size_t (*fn)(size_t);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_shrink");
    }
    return fn ? fn(target) : 0;
}

bool qemu_code_cache_needs_debugger(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_needs_debugger");
    }
    return fn ? fn() : false;
}

size_t qemu_code_cache_grow(size_t target) {
    static size_t (*fn)(size_t);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_grow");
    }
    return fn ? fn(target) : 0;
}

/// Core thread that runs our background QEMU.
static void *qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;

    void *qemu_dll;
    qemu_init_fn qemu_init;
    qemu_main_loop_fn qemu_main_loop;
    qemu_cleanup_fn qemu_cleanup;

    // Provide our QEMU command line and environment...
    char *envp[] = { NULL };

    // clang-format off
    char *argv[] = {
        "qemu-system",

        // Tell QEMU where any option ROMS it might want are hiding.
        "-L", args->bios_dir,

        // We're a terminal; we don't display anything.
        "-display", "none",

        // Guest memory.
        "-m", args->memory_value,

        // Networking.
        //
        // Debug note: one can remove the 127.0.0.1 from the above string to make SSH'ing the VM possible
        // from the debug host. This isn't recommended for debug builds.
        "-device", "virtio-net-pci,id=net1,netdev=net0",
        "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,hostfwd=tcp:127.0.0.1:10022-:22",

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
        "-monitor", args->monitor_channel_args,

        // Monitor conection in-guest tools.
        "-monitor", "tcp:localhost:10045,server,wait=off",

        // Use JIT if we have JIT hacks, and size the code cache if we were asked to.
        "-accel", args->accel_args,

        // Share in our core shared folder, always.
        "-fsdev", args->shared_folder_args,
        "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=shared",

        // These _must_ be last.
        "-loadvm", args->boot_image_name
    };
    // clang-format on

    int argc = ARRAY_SIZE(argv);
    if (args->boot_image_name == NULL) {
        argc -= 2;
    }

    // Open the appropriate QEMU framework...
    qemu_dll = dlopen(args->qemu_image, RTLD_NOW);

    // ... publish it, so the app can ask the running VM about its code cache ...
    atomic_store(&qemu_image_handle, qemu_dll);

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
    free(args->shared_folder_args);
    free(args->memory_value);
    free(args->accel_args);
    if (args->boot_image_name) {
        free(args->boot_image_name);
    }
    free(args);

    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(const char *qemu_path, const char *kernel_path, const char *initrd_path,
                         const char *bios_path, const char *disk_path,
                         const char *shared_folder_path, const char *boot_image_name,
                         const char *memory_value, const char *monitor_socket_path, bool is_jit,
                         bool bless_jit_regions, unsigned int tb_size_mib, unsigned int chunk_mib) {
    pthread_t thread;
    pthread_attr_t qosAttribute;

    // Tell QEMU whether to hand its code buffer to an attached debugger.
    //
    // The app owns this decision, because the app is what arranges for the
    // debugger and its script; QEMU trapping when no script is listening is
    // fatal, and a script waiting for a trap that never comes hangs.
    setenv("TCTISH_JIT_BLESS", bless_jit_regions ? "1" : "0", 1);

    // How much of the code cache to prepare at a time. Travels the same way and for the same
    // reason: the app owns it, because the app is what finds a debugger for each chunk.
    char chunk_value[32];
    snprintf(chunk_value, sizeof(chunk_value), "%u", chunk_mib);
    setenv("TCTISH_CODE_CACHE_CHUNK", chunk_value, 1);

    struct qemu_args *args = calloc(1, sizeof(struct qemu_args));

    args->is_jit = is_jit;
    args->qemu_image = calloc(PATH_MAX, sizeof(char));
    args->kernel_filename = calloc(PATH_MAX, sizeof(char));
    args->initrd_filename = calloc(PATH_MAX, sizeof(char));
    args->bios_dir = calloc(PATH_MAX, sizeof(char));
    args->memory_value = calloc(PATH_MAX, sizeof(char));
    if (boot_image_name) {
        args->boot_image_name = calloc(PATH_MAX, sizeof(char));
    }

    // Create our disk argument.
    args->disk_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->disk_args, ARGUMENT_MAX,
             "media=disk,id=drive1,if=none,file=%s,discard=unmap,detect-zeroes=unmap", disk_path);

    // Create our shared-folder argument.
    args->shared_folder_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->shared_folder_args, ARGUMENT_MAX, "local,path=%s,security_model=none,id=fsdev0",
             shared_folder_path);

    // Create our monitor argument.
    args->monitor_channel_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->monitor_channel_args, ARGUMENT_MAX, "unix:%s,server,nowait",
             monitor_socket_path);

    // Create our accelerator argument.
    //
    // tb_size_mib is passed whatever it is, including zero: QEMU reads `tb-size=0` as "use the
    // default", which is the same decision size_code_gen_buffer() makes when the property is left
    // off entirely. One line, and no branch whose other half nothing ever takes.
    args->accel_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->accel_args, ARGUMENT_MAX, "tcg%s,tb-size=%u", is_jit ? ",split-wx=on" : "",
             tb_size_mib);

    // Copy in each of our filenames/arguments.
    strncpy(args->qemu_image, qemu_path, PATH_MAX - 1);
    strncpy(args->kernel_filename, kernel_path, PATH_MAX - 1);
    strncpy(args->initrd_filename, initrd_path, PATH_MAX - 1);
    strncpy(args->bios_dir, bios_path, PATH_MAX - 1);
    strncpy(args->memory_value, memory_value, PATH_MAX - 1);
    if (boot_image_name) {
        strncpy(args->boot_image_name, boot_image_name, PATH_MAX - 1);
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
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }

    return flags & CS_DEBUGGED;
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
    if (has_debugger_attached()) {
        return true;
    } else {
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
        task_set_exception_ports(mach_task_self(), EXC_MASK_SOFTWARE, port, EXCEPTION_DEFAULT,
                                 THREAD_STATE_NONE);
        pthread_t thread;
        pthread_create(&thread, NULL, exception_handler, (void *)&port);

        return true;
    }
}

/// Returns true iff a debugger is attached to this process right now.
///
/// This is deliberately the same `P_TRACED` test QEMU makes before raising its
/// blessing trap, so that the app waits on precisely the condition QEMU will go
/// on to check. Anything else risks booting QEMU a moment too early, which
/// silently produces a JIT region nobody ever blessed.
bool jit_debugger_tracing(void) {
    struct kinfo_proc info;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    size_t size = sizeof(info);

    info.kp_proc.p_flag = 0;

    if (sysctl(mib, 4, &info, &size, NULL, 0) == -1) {
        return false;
    }

    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

/// Returns true iff this process may make its own mappings executable.
///
/// Not interchangeable with `jit_debugger_tracing()`. `CS_DEBUGGED` is sticky:
/// once any debugger has attached it stays set for the life of the process, so
/// it survives the detach at the end of enablement. This is exactly what makes
/// the ptrace hack useful, and exactly what makes it useless for detecting that
/// a debugger has arrived.
bool jit_may_map_executable(void) {
    return has_debugger_attached();
}

bool set_up_jit(void) {
    // For now, we only have one JIT method, but later we should support
    // some e.g. jailbreak based methods.
    return enable_ptrace_hack();
}
