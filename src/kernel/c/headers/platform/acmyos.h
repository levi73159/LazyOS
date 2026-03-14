#ifndef ACMYOS_H
#define ACMYOS_H

// Use ACPICA's built-in cache — no need to implement AcpiOsCreateCache etc.
#define ACPI_CACHE_T         ACPI_MEMORY_LIST
#define ACPI_USE_LOCAL_CACHE 1

// Use ACPICA's built-in C library functions (memcpy, strlen etc.)
// so you don't need a full libc
#define ACPI_USE_SYSTEM_CLIBRARY 1

#endif
