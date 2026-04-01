const std = @import("std");

pub const escape = @import("escape.zig");
pub const scanner = @import("scanner.zig");
pub const path_mod = @import("path.zig");
pub const writer_mod = @import("writer.zig");
pub const assembler = @import("assembler.zig");

// --- Re-exports for convenience ---

pub const Scanner = scanner.Scanner;
pub const Token = scanner.Token;
pub const Assembler = assembler.Assembler;

pub const PathExpr = path_mod.PathExpr;
pub const path = path_mod.path;
pub const getString = path_mod.getString;
pub const getRaw = path_mod.getRaw;
pub const getInt = path_mod.getInt;
pub const getBool = path_mod.getBool;

pub const JsonWriter = writer_mod.JsonWriter;
pub const jsonWriter = writer_mod.jsonWriter;

test {
    std.testing.refAllDecls(@This());
}
