//
//  SystemProbe.c
//  The part of the System Info debug page that needs C.
//
//  Copyright © 2026 Ara Adkins.
//

#include "SystemProbe.h"

#include <string.h>
#include <sys/sysctl.h>

// The kernel's MIB introspection: {0, 1, oid...} gives an OID's name, and
// {0, 2, oid...} the OID after it. What sysctl(8) uses to list everything.
#define CTL_SYSCTL_NAME 1
#define CTL_SYSCTL_NEXT 2

int system_probe_sysctls(const char *node,
                         void (*found)(const char *name, int64_t value, void *context),
                         void *context) {
    int base[CTL_MAXNAME];
    size_t base_len = CTL_MAXNAME;
    int oid[CTL_MAXNAME];
    size_t oid_len;
    int count = 0;

    if (sysctlnametomib(node, base, &base_len) != 0) {
        return -1;
    }
    memcpy(oid, base, base_len * sizeof(int));
    oid_len = base_len;

    // Depth first from the node itself: each "next" is the following leaf,
    // until one falls outside the node.
    for (;;) {
        int query[CTL_MAXNAME + 2] = { 0, CTL_SYSCTL_NEXT };
        int next[CTL_MAXNAME];
        size_t next_size = sizeof(next);

        memcpy(query + 2, oid, oid_len * sizeof(int));
        if (sysctl(query, (u_int)(oid_len + 2), next, &next_size, NULL, 0) != 0) {
            break;
        }
        oid_len = next_size / sizeof(int);
        memcpy(oid, next, next_size);
        if (oid_len < base_len || memcmp(oid, base, base_len * sizeof(int)) != 0) {
            break;
        }

        int name_query[CTL_MAXNAME + 2] = { 0, CTL_SYSCTL_NAME };
        char name[256];
        size_t name_size = sizeof(name);

        memcpy(name_query + 2, oid, oid_len * sizeof(int));
        if (sysctl(name_query, (u_int)(oid_len + 2), name, &name_size, NULL, 0) != 0) {
            continue;
        }

        // Integers only; the width varies (int or int64_t).
        int64_t value = 0;
        size_t value_size = sizeof(value);
        if (sysctl(oid, (u_int)oid_len, &value, &value_size, NULL, 0) != 0) {
            continue;
        }
        if (value_size == sizeof(int32_t)) {
            value = (int32_t)value;
        } else if (value_size != sizeof(int64_t)) {
            continue;
        }

        found(name, value, context);
        count++;
    }
    return count;
}
