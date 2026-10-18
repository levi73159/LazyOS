# LazyOs stability checklist

Created: 2026-10-18. Based on a targeted source review, not a complete audit.

## Kernel fixes

- [ ] Fix dead-task cleanup: save task.next before freeing task.
- [ ] Validate user pointers: check buffers, strings, and vectors; return EFAULT for invalid memory.
- [ ] Validate file descriptors: reject oversized values before casting to u8.
- [ ] Validate memory ranges: check alignment, overflow, user-space boundaries, and collisions in mmap, munmap, and ELF loading.
- [ ] Zero anonymous memory: clear newly allocated mmap and brk pages before exposing them to a process.
- [ ] Track mapping ownership: record which allocator owns each allocation.
- [ ] Reclaim process resources: free outstanding mappings and close open files on exit.
- [ ] Handle allocation failures: release partially allocated resources when loading or mapping fails.
- [ ] Correct syscall stubs: return ENOSYS when an operation is not implemented.
- [ ] Bound startup arguments: reject arguments that exceed available stack space.

## Verification

- [ ] Repeatedly launch and exit programs without crashes or steadily increasing memory use.
- [ ] Allocate memory, exit without unmapping it, and confirm the memory is reclaimed.
- [ ] Pass null, unmapped, and kernel-space pointers to syscalls without crashing the kernel.
- [ ] Pass oversized file descriptors and confirm EBADF.
- [ ] Test overflowing and overlapping mapping requests.
- [ ] Test malformed ELF files and oversized argument lists.
- [ ] Run true, false, echo, and cat inside LazyOs.
- [ ] Repeat boot and process tests with Intel and AMD CPU configurations.
