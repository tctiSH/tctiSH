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
#include <os/log.h>
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
typedef void (*qemu_init_fn)(int argc, char **argv);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(int status);

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
    char *smp_args;
};

/// Matches `Log.qemu` on the Swift side, so one filter catches both.
static os_log_t QemuLauncherLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("io.ara.tctish.qemu", "qemu");
    });
    return log;
}

/// Frees everything `run_background_qemu` allocated for the VM thread.
static void free_qemu_args(struct qemu_args *args) {
    free(args->qemu_image);
    free(args->bios_dir);
    free(args->kernel_filename);
    free(args->initrd_filename);
    free(args->disk_args);
    free(args->shared_folder_args);
    free(args->monitor_channel_args);
    free(args->memory_value);
    free(args->accel_args);
    free(args->smp_args);
    if (args->boot_image_name) {
        free(args->boot_image_name);
    }
    free(args);
}

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

bool qemu_code_cache_release_all(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_release_all");
    }
    return fn ? fn() : false;
}

bool qemu_code_cache_release_all_outstanding(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_release_all_outstanding");
    }
    return fn ? fn() : false;
}

bool qemu_code_cache_needs_preparing(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_code_cache_needs_preparing");
    }
    // Unanswered, assume it does: preparing a cache that needed nothing costs a grow that is
    // declined, where running one that needed it crashes.
    return fn ? fn() : true;
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

int qemu_backend_current(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_is_tcti");
    }

    // The library is open well before TCG is up, and until it is this answer is useless.
    if (!fn || qemu_code_cache_total() == 0) {
        return -1;
    }
    return fn() ? 1 : 0;
}

bool qemu_backend_native_ready(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_native_ready");
    }
    return fn ? fn() : false;
}

int qemu_backend_prepare_native(void) {
    static int (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_prepare_native");
    }
    return fn ? fn() : 0;
}

bool qemu_backend_release_native(void) {
    static bool (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_release_native");
    }
    return fn ? fn() : false;
}

bool qemu_backend_switch(bool tcti) {
    static bool (*fn)(bool);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_switch");
    }
    return fn ? fn(tcti) : false;
}

size_t qemu_backend_switches(void) {
    static size_t (*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_switches");
    }
    return fn ? fn() : 0;
}

char *qemu_backend_last_error(void) {
    static char *(*fn)(void);
    if (!fn) {
        fn = qemu_symbol("tctish_backend_last_error");
    }
    return fn ? fn() : NULL;
}

bool qemu_vcpu_set_qos(qos_class_t qos_class) {
    static bool (*fn)(int);
    if (!fn) {
        fn = qemu_symbol("tctish_vcpu_set_qos");
    }
    return fn ? fn((int)qos_class) : false;
}

/// The most vCPUs the guest can have.
///
/// QEMU makes a slot for each, and the guest sizes its per-CPU data for each,
/// but only the vCPUs plugged in run. More than the host's cores would only
/// have vCPUs queue for them.
unsigned int qemu_max_vcpus(void) {
    static unsigned int max;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        int cores = 0;
        size_t size = sizeof(cores);

        if (sysctlbyname("hw.logicalcpu_max", &cores, &size, NULL, 0) != 0 || cores < 1) {
            os_log_error(QemuLauncherLog(), "can't count this device's cores; allowing 4 vCPUs");
            cores = 4;
        }
        max = cores > 16 ? 16 : (unsigned int)cores;
    });

    return max;
}

/// The vCPU topology, without the count of vCPUs plugged in at launch.
///
/// Part of the machine signature. The count is not: see `run_background_qemu`.
static const char *qemu_smp_shape(void) {
    static char shape[64];
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        unsigned int max = qemu_max_vcpus();
        snprintf(shape, sizeof(shape), "maxcpus=%u,sockets=1,cores=%u,threads=1", max, max);
    });

    return shape;
}

/// The controller for the disk; the -drive that backs it carries a path and is
/// separate.
///
/// Part of the machine signature, being device state a snapshot holds.
static const char *qemu_disk_device(void) {
    static char device[96];
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        snprintf(device, sizeof(device), "virtio-blk-pci,id=disk1,drive=drive1,num-queues=%u",
                 qemu_max_vcpus());
    });

    return device;
}

/// The parts of the QEMU command line that define the *shape* of the machine.
///
/// Everything here is a literal, and everything dynamic (paths, sizes, the
/// snapshot tag) is deliberately outside it. That split is what lets
/// `qemu_machine_signature()` describe the machine without dragging in values
/// that differ between installs or between launches.
///
/// **A snapshot is only loadable into the machine it was taken from.** Adding a
/// device here, or changing the topology, invalidates every snapshot in
/// existence, handled automatically, because the signature below is
/// derived from this list rather than maintained beside it.
///
/// Order within the list does not matter: QEMU resolves `-device` back-references
/// like `drive=drive1` and `netdev=net0` by id, not by position.
// clang-format off
#define TCTISH_MACHINE_ARGS                                                                        \
    /* We're a terminal; we don't display anything. */                                             \
    "-display", "none",                                                                            \
                                                                                                   \
    /* Networking. Debug note: one can remove the 127.0.0.1 below to make SSH'ing the VM           \
       possible from the debug host. This isn't recommended for debug builds. */                   \
    "-device", "virtio-net-pci,id=net1,netdev=net0",                                               \
    "-netdev", "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100,"                      \
               "hostfwd=tcp:127.0.0.1:10022-:22",                                                  \
                                                                                                   \
    /* Provide our host RNG to our guest; to speed up entropy generation. */                       \
    "-device", "virtio-rng-pci",                                                                   \
                                                                                                   \
    /* Free page reporting: the guest hands back pages it has freed, as it frees them, so its      \
       footprint follows what it is using rather than its high-water mark. Not a balloon -- there  \
       is no target size and nothing on the host decides anything. Page cache is in use as far     \
       as the guest is concerned, so it is never reported. The discard this ends in only frees     \
       memory on Darwin because our QEMU fork maps fresh memory over the range in                  \
       ram_block_discard_range(). */                                                               \
    "-device", "virtio-balloon-pci,free-page-reporting=on",                                        \
                                                                                                   \
    /* Kernel command line. `tcti_disk=file` tells our image to use the provided qcow disk file.   \
                                                                                                   \
       `page_reporting_order=2` reports free blocks from 16 KiB, one host page, up. The default    \
       is 2 MiB, and memory a workload leaves fragmented stays resident on the host even though    \
       the guest counts it free: after a build, about 220 MiB of it.                               \
                                                                                                   \
       `rcu_cpu_stall_suppress=1` because the guest's clock jumps, by design. Our QEMU catches     \
       the clock up after every stop and every snapshot load, so a guest that was away for an      \
       hour comes back an hour later, and RCU reads the jump as a CPU that stalled for an hour.    \
       KVM guests are told when they were paused; under TCG there is no way to tell them. */       \
    "-append", "tcti_disk=file page_reporting.page_reporting_order=2 "                             \
               "rcupdate.rcu_cpu_stall_suppress=1",                                                \
                                                                                                   \
    /* The CPU model: x86-64-v3 (AVX2, FMA, BMI2 and MOVBE on top of SSE4.2), which the software   \
       people want to run increasingly assumes. QEMU's default, qemu64, stops at SSE3.             \
                                                                                                   \
       TCG cannot provide four of Haswell's features and would drop them anyway, warning once per  \
       vCPU on every boot, so they are dropped here instead. None is visible to user space: pcid   \
       and invpcid are TLB tagging, tsc-deadline a timer mode, spec-ctrl a mitigation MSR. */      \
    "-cpu", "Haswell-v4,-pcid,-tsc-deadline,-invpcid,-spec-ctrl",                                  \
                                                                                                   \
    /* Monitor connection for in-guest tools. */                                                   \
    "-monitor", "tcp:localhost:10045,server=on,wait=off",                                          \
                                                                                                   \
    /* Consumes the -fsdev qemu_thread passes separately, which carries the host path. */          \
    "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=shared"
// clang-format on

const char *qemu_machine_signature(void) {
    // Comfortably more than the ~530 bytes the current list needs. Built under
    // dispatch_once rather than a flag, because this is reached both from the
    // main thread at launch and from the boot queue when the epoch is recorded.
    // Those two would write identical bytes, so the race is benign -- but a
    // benign data race is still a data race, and the file already has this idiom.
    static char joined[4096];
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        // The vCPU topology and the disk's queues are the parts that are not
        // literals, as they follow the device; see `qemu_smp_shape` and
        // `qemu_disk_device`. They are in the signature all the same.
        const char *const parts[] = { TCTISH_MACHINE_ARGS, "-smp", qemu_smp_shape(), "-device",
                                      qemu_disk_device() };
        size_t used = 0;

        for (size_t i = 0; i < ARRAY_SIZE(parts); i++) {
            int written =
                snprintf(joined + used, sizeof(joined) - used, "%s%s", i == 0 ? "" : " ", parts[i]);

            // Truncation would make two different machines share a signature,
            // and sharing one is the single failure this must not have: it
            // would resume a snapshot into a machine that cannot hold it.
            //
            // The fallback still varies with the number of arguments, so that
            // adding or removing a device is noticed even here, where a fixed
            // string would quietly make every machine look alike.
            if (written < 0 || (size_t)written >= sizeof(joined) - used) {
                os_log_error(QemuLauncherLog(),
                             "machine signature exceeds %zu bytes; snapshot staleness detection "
                             "is degraded",
                             sizeof(joined));
                snprintf(joined, sizeof(joined), "overflow-%zu", ARRAY_SIZE(parts));
                return;
            }

            used += (size_t)written;
        }
    });

    return joined;
}

/// Core thread that runs our background QEMU.
static void *qemu_thread(void *raw_args) {
    struct qemu_args *args = raw_args;

    void *qemu_dll;
    qemu_init_fn qemu_init;
    qemu_main_loop_fn qemu_main_loop;
    qemu_cleanup_fn qemu_cleanup;

    // Provide our QEMU command line...
    // clang-format off
    char *argv[] = {
        "qemu-system",

        // Tell QEMU where any option ROMS it might want are hiding.
        "-L", args->bios_dir,

        // Guest memory. Not part of TCTISH_MACHINE_ARGS even though it is
        // migrated, because it is a user setting with its own staleness check:
        // see VmMemory.changedSinceLastBoot.
        "-m", args->memory_value,

        // Everything that defines the shape of the machine. Kept in one list so
        // that qemu_machine_signature() describes exactly what is built.
        TCTISH_MACHINE_ARGS,

        // The vCPUs: how many are plugged in at launch, in the topology that
        // qemu_smp_shape() describes and the signature covers. The count is
        // left out of the signature because the app changes it while the VM runs and records what each saved session had.
        "-smp", args->smp_args,

        // The disk's controller, its queues sized to the topology's slots.
        "-device", (char *)qemu_disk_device(),

        // The disk, the kernel and the ramdisk. Paths rather than shape: they
        // differ per install, and what is *in* the kernel and initrd is covered
        // by VmSnapshots.guestEpoch, which digests them.
        "-drive", args->disk_args,
        "-kernel", args->kernel_filename,
        "-initrd", args->initrd_filename,

        // Monitor connection for tctiSH. A socket path, so install-specific.
        "-monitor", args->monitor_channel_args,

        // Use JIT if we have JIT hacks, and size the code cache if we were asked
        // to. Never migrated -- see CodeCache -- so deliberately not part of the
        // machine signature.
        "-accel", args->accel_args,

        // Share in our core shared folder, always. The fsdev carries a host
        // path; the device that consumes it is in TCTISH_MACHINE_ARGS.
        "-fsdev", args->shared_folder_args,

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
    if (qemu_dll == NULL) {
        const char *reason = dlerror();
        os_log_error(QemuLauncherLog(), "could not open %{public}s: %{public}s", args->qemu_image,
                     reason ? reason : "no reason given");
        free_qemu_args(args);
        return NULL;
    }

    // ... publish it, so the app can ask the running VM about its code cache ...
    atomic_store(&qemu_image_handle, qemu_dll);

    // ... and fetch the QEMU functions we need.
    qemu_init = dlsym(qemu_dll, "qemu_init");
    qemu_main_loop = dlsym(qemu_dll, "qemu_main_loop");
    qemu_cleanup = dlsym(qemu_dll, "qemu_cleanup");

    if (qemu_init == NULL || qemu_main_loop == NULL || qemu_cleanup == NULL) {
        os_log_error(QemuLauncherLog(),
                     "%{public}s is missing an entry point (init:%d main_loop:%d cleanup:%d)",
                     args->qemu_image, qemu_init != NULL, qemu_main_loop != NULL,
                     qemu_cleanup != NULL);
        atomic_store(&qemu_image_handle, NULL);
        dlclose(qemu_dll);
        free_qemu_args(args);
        return NULL;
    }

    // Finally, run the lightweight VM.
    qemu_init(argc, argv);
    qemu_cleanup(qemu_main_loop());

    // Clean up the memory allocated for this thread.
    free_qemu_args(args);

    return NULL;
}

/// Spawns a backgroudn thread that runs QEMU.
void run_background_qemu(const char *qemu_path, const char *kernel_path, const char *initrd_path,
                         const char *bios_path, const char *disk_path,
                         const char *shared_folder_path, const char *boot_image_name,
                         const char *memory_value, const char *monitor_socket_path,
                         bool start_native, bool bless_jit_regions, unsigned int tb_size_mib,
                         unsigned int chunk_mib, unsigned int vcpus) {
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
    snprintf(args->monitor_channel_args, ARGUMENT_MAX, "unix:%s,server=on,wait=off",
             monitor_socket_path);

    // Create our accelerator argument.
    //
    // QEMU starts the named backend: TCTI (tcti=on), which needs no JIT, or the native JIT. It can
    // be switched dynamically while it runs. split-wx is for the native code's buffer, which is
    // mapped split whenever it is mapped.
    //
    // tb_size_mib is passed regardless of size: QEMU reads `tb-size=0` as "use the default", which
    // is the same decision size_code_gen_buffer() makes when the property is left off entirely. One
    // line, and no branch whose other half nothing ever takes.
    args->accel_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->accel_args, ARGUMENT_MAX, "tcg,tcti=%s,split-wx=on,tb-size=%u",
             start_native ? "off" : "on", tb_size_mib);

    // Create our vCPU argument. Plugged in in order from core 0, which is how
    // the app keeps them, so that a snapshot taken with this many loads with
    // nothing to change; QEMU brings the machine to a snapshot's vCPUs either way.
    unsigned int max_vcpus = qemu_max_vcpus();
    if (vcpus < 1 || vcpus > max_vcpus) {
        os_log_error(QemuLauncherLog(), "asked for %u vCPUs of %u; using %u", vcpus, max_vcpus,
                     vcpus < 1 ? 1 : max_vcpus);
        vcpus = vcpus < 1 ? 1 : max_vcpus;
    }
    args->smp_args = calloc(ARGUMENT_MAX, sizeof(char));
    snprintf(args->smp_args, ARGUMENT_MAX, "cpus=%u,%s", vcpus, qemu_smp_shape());

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
