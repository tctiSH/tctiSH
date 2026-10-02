//
//  SystemProbe.h
//  The part of the System Info debug page that needs C.
//
//  Copyright © 2026 Ara Adkins.
//

#ifndef SystemProbe_h
#define SystemProbe_h

#include <stdint.h>

/// Calls `found` with the name and value of every integer sysctl under `node`
/// (such as "hw.optional"), in the kernel's order.
///
/// Walks the MIB with the kernel's own "next" and "name" queries, so it finds
/// feature flags this code has never heard of. Returns how many it found, or
/// -1 if there is no such node.
int system_probe_sysctls(const char *node,
                         void (*found)(const char *name, int64_t value, void *context),
                         void *context);

#endif /* SystemProbe_h */
