pub const InterruptFrame = packed struct {
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    useless: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,

    interrupt_number: u32,
    error_code: u32,

    // pushed by the processor
    eip: u32,
    cs: u32,
    eflags: u32,
    esp: u32,
    ss: u32,
};
