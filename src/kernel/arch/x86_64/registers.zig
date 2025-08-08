//! Registers of an x86-64 processor

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2024-2025 Samuel Fiedler

/// CR0
/// Contains system control flags that control operating mode and states of the processor.
/// From the Intel SDM Volume 3A (December 2023), Chapter 2.5
pub const CR0 = packed struct(u64) {
    /// Protection Enable
    /// Enables protected mode when set; enables real-address mode when clear.
    pe: bool,
    /// Monitor Coprocessor
    /// Controls the interaction of the WAIT (or FWAIT) instruction with the TS flag (bit 3 of CR0).
    /// If the MP flag is set, a WAIT instruction generates a device-not-available exception (#NM) if the TS flag is also set.
    /// If the MP flag is clear, the WAIT instruction ignores the setting of the TS flag.
    mp: bool,
    /// Emulation
    /// Indicates that the processor does not have an internal or external x87 FPU when set; indicates an x87 FPU is present when clear.
    /// This flag also affects the execution of MMX/SSE/SSE2/SSE3/SSSE3/SSE4 instructions.
    em: bool,
    /// Task Switched
    /// Allows the saving of the x87 FPU/MMX/SSE/SSE2/SSE3/SSSE3/SSE4
    /// context on a task switch to be delayed until an x87 FPU/MMX/SSE/SSE2/SSE3/SSSE3/SSE4 instruction is
    /// actually executed by the new task. The processor sets this flag on every task switch and tests it when
    /// executing x87 FPU/MMX/SSE/SSE2/SSE3/SSSE3/SSE4 instructions.
    ///   - If the TS flag is set and the EM flag (bit 2 of CR0) is clear, a device-not-available exception (#NM) is
    ///     raised prior to the execution of any x87 FPU/MMX/SSE/SSE2/SSE3/SSSE3/SSE4 instruction; with the
    ///     exception of PAUSE, PREFETCHh, SFENCE, LFENCE, MFENCE, MOVNTI, CLFLUSH, CRC32, and POPCNT.
    ///     See the paragraph below for the special case of the WAIT/FWAIT instructions.
    ///   - If the TS flag is set and the MP flag (bit 1 of CR0) and EM flag are clear, an #NM exception is not raised
    ///     prior to the execution of an x87 FPU WAIT/FWAIT instruction.
    ///   - If the EM flag is set, the setting of the TS flag has no effect on the execution of x87
    ///     FPU/MMX/SSE/SSE2/SSE3/SSSE3/SSE4 instructions.
    ts: bool,
    /// Extension Type
    /// Reserved in the Pentium 4, Intel Xeon, P6 family, and Pentium processors.
    /// In the Pentium 4, Intel Xeon, and P6 family processors, this flag is hardcoded to 1.
    /// In the Intel386 and Intel486 processors, thi sflag indicates support of Intel 387 DX math coprocessor instructions when set.
    et: bool,
    /// Numeric Error
    /// Enables the native (internal) mechanism for reporting x87 FPU errors when set; enables the PC-style x87 FPU error reporting mechanism when clear.
    ne: bool,
    /// 10 reserved bits
    res1: u10 = 0,
    /// Write Protect
    /// When set, inhibits supervisor-level procedures from writing into read-only pages; when clear, allows supervisor-level procedures to write into read-only pages (regardless of the U/S bit setting).
    wp: bool,
    /// 1 reserved bit
    res2: u1 = 0,
    /// Alignment mask
    /// Enables automatic alignment checking when set; disables alignment checking when clear.
    am: bool,
    /// 10 reserved bits
    res3: u10 = 0,
    /// Not Write-through
    /// When the NW and CD flags are clear, write-back or write-through is enabled for writes that hit the cache and invalidation cycles are enabled.
    nw: bool,
    /// Cache Disable
    /// When the CD and NW flags are clear, caching of memory locations for the whole of physical memory in the processor's internal (and external) caches is enabled.
    /// When the CD flag is set, caching is restricted as described in Table 12-5.
    cd: bool,
    /// Paging
    /// Enables paging when set; disables paging when clear.
    pg: bool,
    /// 32 reserved bits
    res4: u32 = 0,

    /// Get this control register from the processor
    pub fn get() CR0 {
        const value = asm volatile ("mov %cr0, %[ret]"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(value);
    }

    /// Set the register in the processor
    pub fn set(cr0: CR0) void {
        const value: u64 = @bitCast(cr0);
        asm volatile ("mov %[val], %cr0"
            :
            : [val] "{rax}" (value),
        );
    }
};

// CR1
// Reserved

/// CR2
/// Contains the page-fault linear address (the linear address that caused a page fault).
/// From the Intel SDM Volume 3A (December 2023), Chapter 2.5
pub const CR2 = packed struct(u64) {
    /// The address
    val: u64,

    /// Get this control register from the processor
    pub fn get() CR2 {
        const value = asm volatile ("mov %cr2, %[ret]"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(value);
    }

    // Setting that register is not logical
};

/// Control Register 3
/// Contains the physical address of the base of the paging-structure hierarchy and two flags (PCD and PWT).
/// From the Intel SDM Volume 3A (December 2023), Chapter 2.5
pub const CR3 = packed struct(u64) {
    /// 3 reserved bits
    res1: u3 = 0,
    /// Page Write-Through
    /// Controls the memory type used to access the first paging structure of the current paging-structure hierarchy
    pwt: bool,
    /// Page-level Cache Disable
    /// Controls the memory type used to access the first paging structure of the current paging-structure hierarchy
    pcd: bool,
    /// 7 reserved bits
    res2: u7 = 0,
    /// Page-Directory Base
    addr: u52,

    /// Get this control register from the processor
    pub fn get() CR3 {
        const value = asm volatile ("mov %cr3, %[ret]"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(value);
    }

    /// Set this control register in the processor
    pub fn set(cr3: CR3) void {
        const value: u64 = @bitCast(cr3);
        asm volatile ("mov %[val], %cr3"
            :
            : [val] "{rax}" (value),
        );
    }
};

/// CR4
/// Contains a group of flags that enable several architectural extensions, and indicate operating system or executive support for specific processor capabilities.
/// From the Intel SDM Volume 3A (December 2023), Chapter 2.5
pub const CR4 = packed struct(u64) {
    /// Virtual-8086 Mode Extensions
    /// Enables interrupt- and exception-handling extensions in virtual-8086 mode when set; disables the extensions when clear.
    vme: bool,
    /// Protected-Mode Virtual Interrupts
    /// Enables hardware support for a virtual interrupt flag (VIF) in protected mode when set; disables the VIF flag in protected mode when clear.
    pvi: bool,
    /// Time Stamp Disable
    /// Restricts the execution of the RDTSC instruction to procedures running at privilege level 0 when set; allows RDTSC instruction to be executed at any privilege level when clear.
    tsd: bool,
    /// Debugging Extensions
    /// References to debug registers DR4 and DR5 cause an undefined opcode (#UD) exception to be generated when set; when clear, processor aliases references to registers DR4 and DR5 for compatibility with software written to run on earlier IA-32 processors.
    de: bool,
    /// Page Size Extensions
    /// Enables 4MB pages with 32bit paging when set; restricts 32bit paging to pages of 4KB when clear.
    pse: bool,
    /// Physical Address Extension
    /// When set, enables paging to produce physical addresses with more than 32 bits. When clear, restricts physical addresses to 32 bits.
    /// PAE must be set before entering IA-32e mode.
    pae: bool,
    /// Machine-Check Enable
    /// Enables the machine-check exception when set; disables the machine-check exception when clear.
    mce: bool,
    /// Page Global Enable
    /// (Introduced in the P6 family processors.) Enables the global page feature when set; disables the global page feature when clear.
    pge: bool,
    /// Performance-Monitoring Counter Enable
    /// Enables execution of the RDPMC instruction for programs or procedures running at any protectiion level when set; RDPMC instruction can be executed only at protection level 0 when clear.
    pce: bool,
    /// Operating System Support for FXSAVE and RXRSTOR instructions
    /// When set, this flag:
    ///   1. Indicates to software that the operating system supports the use of the FXSAVE and FXRSTOR instruction
    ///   2. Enables the FXSAVE and FXRSTOR instructions to save and restore the contents of the XMM and MXCSR registers along with the contents of the x87 FPU and MMX registers
    ///   3. Enables the processor to execute SSE/SSE2/SSE3/SSSE3/SSE4 instructions, with exceptions of PAUSE, PREFETCH, SFENCE, LFENCE, MFENCE, MOVNTI, CLFLUSH, CRC32 and POPCNT
    /// If this flag is clear, the FXSAVE and FXRSTOR instructions will save and restore the contents of the x87 FPU and MMX registers, but they may not save and restore the contents of the XMM and MXCSR registers.
    /// Also, the processor will generate an invalid opcode exception (#UD) if it attemps to execute any SSE/SSE2/SSE3 instruction, with the exception of PAUSE, PREFETCH, SFENCE, LFENCE, MFENCE, MOVNTI, CLFLUSH, CRC32 and POPCNT
    /// The operating system must explicitly set this flag.
    osfxsr: bool,
    /// Operating System Support for Unmasked SIMD Floating-Point Exceptions
    /// When set, indicates that the operating system supports the handling of unmasked SIMD floating-point exceptipmns through an exception handler that is invoked when a SIMD floating-point exception (#XM) is generated.
    /// If this flag is not set, the processor will generate an invalid opcode exception (#UD) whenever it detects an unmasked SIMD floating-point exception.
    /// The operating system must explicitly set this flag.
    osxmmexcpt: bool,
    /// User-Mode Instruction Prevention
    /// When set, the following instructions cannot be executed if CPL > 0: SDGT SIDT SLDT SMSW, and STR. An attempt at such execution causes a general-protection exception (#GP).
    umip: bool,
    /// 57bit linear addresses
    /// When set in IA-32e mode, the processor uses 5-level paging to translate 57bit linear addresses. When clear in IA-32e mode, the processor uses 4-level paging to translate 48bit linear addresses.
    /// This bit cannot be modified in IA-32e mode.
    la57: bool,
    /// VMX-Enable
    /// Enables VMX operation when set.
    vmxe: bool,
    /// SMX-Enable
    /// Enables SMX operation when set.
    smxe: bool,
    /// Reserved
    res1: u1 = 0,
    /// FSGSBASE-Enable
    /// Enables the instructions RDFSBASE, RDGSBASE, WRFSBASE and WRGSBASE.
    fsgsbase: bool,
    /// PCID-Enable
    /// Enables process-context identifiers (PCIDs) when set.
    pcide: bool,
    /// XSAVE and Processor Extended States-Enable
    /// When set, this flag:
    ///   1. Indicates (via CPUID.01H:ECX.OSXSAVE[bit 27]) that the operating system supports the use of the XGETBV, XSAVE and XRSTOR instructions by general software
    ///   2. Enables the XSAVE and XRSTOR instructions to save and restore the x87 FPU state (including MMX registers)
    ///   3. Enables the processor to execute XGETBV and XSETBV instructions in order to read and write XCR0
    osxsave: bool,
    /// Key-Locker-Enable
    /// When set, the LOADIWKEY instruction is enabled and, if AES Key Locker instructions are activated by firmware, CPUID.19H:EBX.AESKLE[bit 0] is enumerated as 1 and the AES Key Locker instructions are enabled.
    /// When clear, CPUID.19H:EBX.AESKLE[bit 0] is enumerated as 0 and any key locked instruction causes an invalid-opcode exception (#UD)
    kl: bool,
    /// SMEP-Enable
    /// Enables supervisor-mode execution prevention when set.
    smep: bool,
    /// Enables supervisor-mode access prevention when set.
    smap: bool,
    /// Enable protection keys for user-mode pages
    /// 4-level and 5-level paging associate each user-mode linear address with a protection key.
    /// When set, this flag indicates (via CPUID.(EAX=07H,ECX=0H):ECX.OSPKE [bit4]) that the operating system supports the use of the PKRU register to specify, for each protection key, whether user-mode linear addresses with that protection key can be read or written.
    pke: bool,
    /// Control-flow Enforcement Technology
    /// Enables control-flow enforcement technology when set.
    cet: bool,
    /// Enable protection keys for supervisor-mode pages
    /// 4-level paging and 5-level paging associate each supervisor-mode linear address with a protection key.
    /// When set, this flag allows use of the IA32_PKRS MSR to specify, for each protection key, whether supervisor-mode linear addresses with that protection key can be read or written.
    pks: bool,
    /// User Interrupts Enable
    /// Enables user interrupts when set, including user-interrupt delivery, user-interrupt notification identification, and the user-interrupt instructions.
    uintr: bool,
    /// 38 reserved bits
    res2: u38 = 0,

    /// Get this control register from the processor
    pub fn get() CR4 {
        const value = asm volatile ("mov %cr4, %[ret]"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(value);
    }

    /// Set this control register in the processor
    pub fn set(cr4: CR4) void {
        const value: u64 = @bitCast(cr4);
        asm volatile ("mov %[val], %cr4"
            :
            : [val] "{rax}" (value),
        );
    }
};

/// CR8
/// Provides read and write access to the Task Priority Register (TPR)
/// From the Intel SDM Volume 3A (December 2023), Chapter 2.5
pub const CR8 = packed struct(u64) {
    /// This sets the threshold value corresponding th the highest-priority interrupt to be blocked. A value of 0 means all interrupts are enabled.
    /// This field is available in 64-bit mode. A value of 15 means all interrupts will be disabled.
    tpl: u4,
    /// 60 reserved bits
    res1: u60 = 0,

    /// Get this control register from the processor
    pub fn get() CR8 {
        const value = asm volatile ("mov %cr8, %[ret]"
            : [ret] "={rax}" (-> u64),
        );
        return @bitCast(value);
    }

    /// Set this control register in the processor
    pub fn set(cr8: CR8) void {
        const value: u64 = @bitCast(cr8);
        asm volatile ("mov %[val], %cr8"
            :
            : [val] "{rax}" (value),
        );
    }
};

/// CPU Features
/// From the Intel (R) 64 and IA-32 Architectures Software Developer's Manual, Vol. 2A; Chapter 3.3 (CPUID)
/// (EAX=01h; Table 3-10 and 3-11)
pub const CpuFeatures = packed struct(u64) {
    // ECX

    /// Streaming SIMD Extensions 3
    /// A value of 1 indicates the processor supports this technology.
    sse3: bool,
    /// PCLMULQDQ
    /// A value of 1 indicates the processor supports the PCLMULQDQ instruction.
    pclmulqdq: bool,
    /// 64bit DS Area
    /// A value of 1 indicates the processor supports DS area using 64bit layout.
    dtes64: bool,
    /// MONITOR/MWAIT
    /// A value of 1 indicates the processor supports this features.
    monitor: bool,
    /// CPL Qualified Debug Store
    /// A value of 1 indicates the processor supports the extensions to the Debug Store feature to allow for branch message storage qualified by CPL.
    ds_cpl: bool,
    /// Virtual Machine Extensions
    /// A value of 1 indicates that the processor supports this technology.
    vmx: bool,
    /// Safer Mode Extensions
    /// A value of 1 indicates that the processor supports this technology.
    smx: bool,
    /// Enhanced Intel (R) SpeedStep Technology
    /// A value of 1 indicates that the processor supports this technology.
    eist: bool,
    /// Thermal Monitor 2
    /// A value of 1 indicates whether the processor supports this technology.
    tm2: bool,
    /// Supplemental Streaming SIMD Extensions 3
    /// A value of 1 indicates the presence of this technology.
    /// A value of 0 indicates the instructions are not present in the processor.
    ssse3: bool,
    /// L1 Context ID
    /// A value of 1 indicates the L1 data cache mode can be set to either adaptive mode or shared mode.
    /// A value of 0 indicates this feature is not supported.
    cnxt_id: bool,
    /// A value of 1 indicates the processor supports IA32_DEBUG_INTERFACE MSR for silicon debug.
    sdbg: bool,
    /// A value of 1 indicates the processor supports FMA extensions using YMM state.
    fma: bool,
    /// CMPXCHG16B Available
    /// A value of 1 indicates that the feature is available.
    cmpxchg16b: bool,
    /// xTPR Update Control
    /// A value of 1 indicates that the processor supports changing IA_MISC_ENABLE[bit 32].
    xtpr_update_control: bool,
    /// Perfmon and Debug Capability
    /// A value of 1 indicates the processor supports the performance and debug feature indication MSR IA32_PERF_CAPABILITIES.
    pdcm: bool,
    /// Reserved
    res1: u1 = 0,
    /// Process-context identifiers
    /// A value of 1 indicates that the processor supports PCIDs and that software may set CR4.PCIDE to 1.
    pcid: bool,
    /// A value of 1 indicates the processor supportsr the ability to prefetch data from a memory mapped device
    dca: bool,
    /// A value of 1 indicates that the processor supports SSE4.1.
    sse4_1: bool,
    /// A value of 1 indicates that the processor supports SSE4.2.
    sse4_2: bool,
    /// A value of 1 indicates that the processor supports x2APIC feature.
    x2apic: bool,
    /// A value of 1 indicates that the processor supports MOVBE instruction.
    movbe: bool,
    /// A value of 1 indicates that the processor supports the POPCNT instruction
    popcnt: bool,
    /// A value of 1 indicates that the processor's local APIC timer supports one-shot operation using a TSC deadline value.
    tsc_deadline: bool,
    /// A value of 1 indicates that the processor supports the AESNI instruction extensions.
    aesni: bool,
    /// A value of 1 indicates that the procesor supports the XSAVE/XRSTOR processor extended states feature, the XSETBV/XGETBV instructions, and XCR0
    xsave: bool,
    /// A value of 1 indicates that the OS has set CR4.OSXSAVE[bit 18] to enable XSETBV/XGETBV instructions to access XCR0 and to support processor extended state management using XSAVE/XRSTOR
    osxsave: bool,
    /// A value of 1 indicates the processor supports the AVX instruction extensions
    avx: bool,
    /// A value of 1 indicates that processor supports 16bit floating-point conversion instruction
    f16c: bool,
    /// A value of 1 indicates that processor supports RDRAND instruction
    rdrand: bool,
    /// Always 0
    not_used: u1 = 0,

    // EDX

    /// Floating-Point Unit On-Chip
    /// The processor contains an x87 FPU.
    fpu: bool,
    /// Virtual 8086 Mode Enhancements
    /// Virtual 8086 mode enhancements, including CR4.VME for controlling the feature, CR4.PVI for protected mode virtual interrupts, software interrupt indirection, expansion of the TSS with the software indirection bitmap and EFLAGS.VIF and EFLAGS.VIP flags.
    vme: bool,
    /// Debugging Extensions
    /// Support for I/O breakpoints, including CR4.DE for controlling the feature, and optional trapping of accesses to DR4 and DR5.
    de: bool,
    /// Page Size Extension
    /// Large pages of size 4MB are supported, including CR4.PSE for controlling the feature, the defined dirty bit in PDE, optional reserved bit trapping in CR3, PDEs, and PTEs.
    pse: bool,
    /// Time Stamp Counter
    /// The RDTSC instruction is supported, including CR4 for controlling privilege.
    tsc: bool,
    /// Model Specific Registers RDMSR and WRMSR Instructions
    /// The RDMSR and WRMSR instructions are supported. Some of the MSRs are implementation dependent.
    msr: bool,
    /// Physical Address Extension
    /// Physical addresses greater than 32 bits are supported: extended page table entry formats, an extra level in the page translation tables is defined, 2MB pages are supported instead of 4MB pages if PAE bit is 1.
    pae: bool,
    /// Machine Check Exception
    /// Exception 18 is defined for Machine Checks, including CR4.CME for controlling the feature.
    mce: bool,
    /// CMPXCHG8B Instruction
    /// The compage-and-exchange 8 bytes (64 bits) instruction is supported (implicitly locked and atomic)
    cx8: bool,
    /// APIC On-Chip
    /// The processor contains an Advanced Programmable Interrupt Controller (APIC), responding to mmory mapped commands in the physical address range FFFE0000 to FFFE0FFF
    apic: bool,
    /// Reserved
    res2: u1 = 0,
    /// SYSENTER and SYSEXIT Instructions
    /// The SYSENTER and SYSEXIT and associated MSRs are supported.
    sep: bool,
    /// Memory Type Range Registers
    /// MTRRs are supported.
    mtrr: bool,
    /// Page Global Bit
    /// The global bit is supported in paging-structure entries that map a page, indicating TLB entries that are common to different processes and need not be flushed. The CR4.PGE bit controls this feature.
    pge: bool,
    /// Machine Check Architecture
    /// A value of 1 indicates the Machine Check Architecture of reporting machine errors is supported.
    mca: bool,
    /// Conditional Move Instructions
    /// The conditional move instruction CMOV is supported. In addition, if x87 FPU is present as indicated by the CPUID.FPU feature bit, then the FCOMI and FCMOV instructions are supported.
    cmov: bool,
    /// Page Attribute Table
    /// Page Attribute Table is supported. This feature augments the MTRRs, allowing an operating system to specify attributes of memory accessed through a linear address on a 4KB granularity.
    pat: bool,
    /// 36bit Page Size Extension
    /// 4MB pages addressing physical memory beyond 4GB are supported with 32bit paging. This feature indicates that upper bits of the physical address of a 4MB page are encoded in bits 20:13 of the page-directory entry. Such physical addresses are limited by MAXPHYADDR and may be up to 40 bits in size.
    pse_36: bool,
    /// Processor Serial Number
    /// The processor supports the 96-bit processor identification number feature and the feature is enabled.
    psn: bool,
    /// CLFLUSH Instruction
    /// CLFLUSH Instruction is supported
    clfsh: bool,
    /// Reserved
    res3: u1 = 0,
    /// Debug Store
    /// The processor supports the ability to write debug information into a memory resident buffer.
    ds: bool,
    /// Thermal Monitor and Software Controlled Clock Facilities
    /// The processor implements internal MSRs that allow processor temperature to be monizored and processor performance to be modulated in predifined duty cycles under software control.
    acpi: bool,
    /// Intel MMX Technology
    /// The processor supports the Intel MMX technology.
    mmx: bool,
    /// FXWSAVE and FXRSTOR Instructions
    /// The FXSAVE and FXRSTOR instructions are supported for fast save and restore of the floating-point context. Presence of this bit also indicates that CR4.OSFXSR is available for an operating system to indicate that it supports the FXSAVE and FXRSTOR instructions.
    fxsr: bool,
    /// SSE
    /// The processor supports the SSE extensions.
    sse: bool,
    /// SSE2
    /// The processor supports the SSE2 extensions.
    sse2: bool,
    /// Self Snoop
    /// The processor supports the management of conflicting memory types by perfoming a snoop of its own cache structure for transactions issued to the bus.
    ss: bool,
    /// Max APIC IDs reserved field is Valid
    /// A value of 0 for HTT indicates there is only a single logical processor in the package and software should assume only a single APIC ID is reserved.
    /// A value of 1 for HTT indicates the value in CPUID.1.EBX[23:16] is valid for the package.
    htt: bool,
    /// Thermal Monitor
    /// The processor implements the thermal monitor automatic thermal control circuitry (TCC).
    tm: bool,
    /// Reserved
    res4: u1 = 0,
    /// Pending Break Enable
    /// The processor supports the use of the FERR#/PBE# pin when the processor is in the stop-clock state (STPCLK# is asserted) to signal the processor that an interrupt is pending and that the processor should return to normal operation to handle the interrupt.
    pbe: bool,

    /// Query all CPU features
    pub fn get() CpuFeatures {
        return asm volatile ("cpuid; shlq $32, %rdx; or %rdx, %rcx"
            : [ret] "={rcx}" (-> CpuFeatures),
            : [param] "{eax}" (1),
            : "rcx", "rdx"
        );
    }
};

/// Get value from RSP register
pub inline fn getRSP() usize {
    return asm volatile ("mov %rsp, %[ret]"
        : [ret] "={rax}" (-> usize),
    );
}

/// Get value from Instruction Pointer register
pub inline fn getIP() usize {
    return asm volatile ("lea (%rip), %[ret]"
        : [ret] "={rax}" (-> usize),
    );
}

/// Write in the Instruction Pointer register and jump there
pub inline fn jumpIP(ip: usize, sp: usize, param: anytype) noreturn {
    asm volatile ("push %[ip]; ret"
        :
        : [ip] "{rax}" (ip),
          [sp] "{rsp}" (sp - 8),
          [bp] "{rbp}" (sp - 8),
          [param] "{rdi}" (param),
    );

    while (true) {}
}

/// Set the value of the CS register
pub inline fn setCS(value: u16) void {
    // a bit more difficult than other things because it can't be loaded via MOV
    // so we first load it and then change it via far return
    _ = asm volatile (
        \\push %[val]
        \\lea setCSOut(%rip), %[tmp]
        \\push %[tmp]
        \\lretq
        \\setCSOut:
        : [tmp] "={rax}" (-> usize),
        : [val] "{rcx}" (@as(u64, value)),
        : "memory"
    );
}

/// Set the value of all data segment registers (DS, ES, FS, GS, SS)
pub inline fn setDataSegments(value: u16) void {
    asm volatile (
        \\movw %[val], %ds
        \\movw %[val], %es
        \\movw %[val], %fs
        \\movw %[val], %gs
        \\movw %[val], %ss
        :
        : [val] "{rax}" (value),
    );
}

/// EAX and EDX together
pub const MSR = packed struct(u64) {
    /// EAX
    eax: u32,
    /// EDX
    edx: u32,
};

/// Set Model Specific Register
pub inline fn setMSR(register: u32, value: MSR) void {
    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (value.eax),
          [high] "{edx}" (value.edx),
          [reg] "{ecx}" (register),
    );
}

// TODO: add register enum for MSR

/// Get Model Specific Register
pub inline fn getMSR(register: u32) MSR {
    var eax: u32 = 0;
    var edx: u32 = 0;
    asm volatile ("rdmsr"
        : [low] "={eax}" (eax),
          [high] "={edx}" (edx),
        : [reg] "{ecx}" (register),
    );
    return .{
        .eax = eax,
        .edx = edx,
    };
}

/// RFLAGS Register
pub const RFLAGS = packed struct(u64) {
    /// Carry Flag
    cf: bool,
    /// Reserved
    res1: u1 = 1,
    /// Parity Flag
    pf: bool,
    /// Reserved
    res2: u1 = 0,
    /// Auxiliary Carry Flag
    af: bool,
    /// Reserved
    res3: u1 = 0,
    /// Zero Flag
    zf: bool,
    /// Sign Flag
    sf: bool,
    /// Trap Flag
    tf: bool,
    /// Interrupt Enable Flag
    @"if": bool,
    /// Direction Flag
    df: bool,
    /// Overflow Flag
    of: bool,
    /// I/O Privilege Level
    iopl: u2,
    /// Nested Task
    nt: bool,
    /// Reserved
    res4: u1 = 0,
    /// Resume Flag
    rf: bool,
    /// Virtual-8086 Mode
    vm: bool,
    /// Alignment Check / Access Control
    ac: bool,
    /// Virtual Interrupt Flag
    vif: bool,
    /// Virtual Interrupt Pending
    vip: bool,
    /// ID Flag
    id: bool,
    /// Reserved
    res5: u42,
};

/// Get RFLAGS
pub inline fn getRFLAGS() RFLAGS {
    return asm volatile (
        \\pushfq
        \\pop %[ret]
        : [ret] "={rax}" (-> RFLAGS),
    );
}

/// Set RFLAGS
pub inline fn setRFLAGS(rflags: RFLAGS) void {
    asm volatile (
        \\push %[val]
        \\popfq
        :
        : [val] "{rax}" (rflags),
    );
}

/// Invalidate TLB Entry
pub inline fn invlpg(entry: usize) void {
    asm volatile ("invlpg (%[entry])"
        :
        : [entry] "{rax}" (entry),
    );
}

/// Halt
pub inline fn halt() void {
    asm volatile ("hlt");
}
// TODO: maybe move this into another namespace?
