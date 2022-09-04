//
//  qemu_launcher.h
//  tctiSH
//
//  Created by Kate Temkin on 9/1/22.
//  Copyright © 2022 Kate Temkin. All rights reserved.
//

#ifndef qemu_launcher_h
#define qemu_launcher_h

#include <stdbool.h>

void run_background_qemu(const char *kernel_path,
                         const char *initrd_path,
                         const char *bios_path,
                         const char *disk_path,
                         bool preferABootImage);


//
// Types lifted from QEMU, for interop.
//
/*
typedef enum QapiErrorClass {
    QAPI_ERROR_CLASS_GENERICERROR,
    QAPI_ERROR_CLASS_COMMANDNOTFOUND,
    QAPI_ERROR_CLASS_DEVICENOTACTIVE,
    QAPI_ERROR_CLASS_DEVICENOTFOUND,
    QAPI_ERROR_CLASS_KVMMISSINGCAP,
    QAPI_ERROR_CLASS__MAX,
} QapiErrorClass;

typedef enum ErrorClass {
     ERROR_CLASS_GENERIC_ERROR = QAPI_ERROR_CLASS_GENERICERROR,
     ERROR_CLASS_COMMAND_NOT_FOUND = QAPI_ERROR_CLASS_COMMANDNOTFOUND,
     ERROR_CLASS_DEVICE_NOT_ACTIVE = QAPI_ERROR_CLASS_DEVICENOTACTIVE,
     ERROR_CLASS_DEVICE_NOT_FOUND = QAPI_ERROR_CLASS_DEVICENOTFOUND,
     ERROR_CLASS_KVM_MISSING_CAP = QAPI_ERROR_CLASS_KVMMISSINGCAP,
} ErrorClass;

struct Error
{
    char *msg;
    ErrorClass err_class;
    const char *src, *func;
    int line;
    void *hint;
};
*/


#endif /* qemu_launcher_h */
