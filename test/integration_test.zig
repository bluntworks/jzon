const std = @import("std");
const jzon = @import("jzon");

test {
    std.testing.refAllDecls(@This());
    _ = jzon;
}
