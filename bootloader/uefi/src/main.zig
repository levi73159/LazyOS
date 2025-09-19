const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;

pub fn main() uefi.Status {
    const sys_table = uefi.system_table;
    const conout = sys_table.con_out.?;
    _ = conout.clearScreen();
    _ = conout.outputString(utf16("Hello, World!\n"));

    return .timeout;
}
