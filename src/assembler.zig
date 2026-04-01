const std = @import("std");

pub const MAX_DEPTH = 256;

pub const Assembler = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    state: State = .empty,
    depth: u32 = 0,
    in_string: bool = false,
    escape_next: bool = false,

    pub const State = enum {
        empty,
        incomplete,
        complete,
        invalid,
    };

    pub const AssemblerError = error{
        AssemblerInvalid,
    };

    pub fn init() Assembler {
        return .{};
    }

    pub fn deinit(self: *Assembler, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    /// Feed a chunk of partial JSON. Returns the current state.
    pub fn feed(self: *Assembler, allocator: std.mem.Allocator, chunk: []const u8) (AssemblerError || std.mem.Allocator.Error)!State {
        if (self.state == .invalid) return error.AssemblerInvalid;
        if (self.state == .complete) return error.AssemblerInvalid;

        try self.buf.appendSlice(allocator, chunk);

        for (chunk) |c| {
            if (self.escape_next) {
                self.escape_next = false;
                continue;
            }
            if (self.in_string) {
                switch (c) {
                    '"' => self.in_string = false,
                    '\\' => self.escape_next = true,
                    else => {},
                }
                continue;
            }
            switch (c) {
                '"' => self.in_string = true,
                '{', '[' => {
                    self.depth += 1;
                    if (self.depth > MAX_DEPTH) {
                        self.state = .invalid;
                        return error.AssemblerInvalid;
                    }
                },
                '}', ']' => {
                    if (self.depth == 0) {
                        self.state = .invalid;
                        return error.AssemblerInvalid;
                    }
                    self.depth -= 1;
                },
                else => {},
            }
        }

        if (self.state == .empty and self.buf.items.len > 0) {
            self.state = .incomplete;
        }

        if (self.depth == 0 and !self.in_string and self.buf.items.len > 0) {
            self.state = .complete;
        }

        return self.state;
    }

    /// Returns true if the assembled JSON is complete.
    pub fn isComplete(self: *const Assembler) bool {
        return self.state == .complete;
    }

    /// Returns the accumulated bytes. Asserts the assembler is complete.
    pub fn slice(self: *const Assembler) []const u8 {
        std.debug.assert(self.state == .complete);
        return self.buf.items;
    }

    /// Reset for reuse. Clears the buffer but keeps the allocation.
    pub fn reset(self: *Assembler) void {
        self.buf.clearRetainingCapacity();
        self.state = .empty;
        self.depth = 0;
        self.in_string = false;
        self.escape_next = false;
    }
};

// --- Tests ---

test "assembler detects complete simple object" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"cmd\":\"ls\"}");
    try std.testing.expect(asmb.isComplete());
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", asmb.slice());
}

test "assembler accumulates partial chunks" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"cmd\":");
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, "\"ls\"}");
    try std.testing.expect(asmb.isComplete());
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", asmb.slice());
}

test "assembler handles nested brackets" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"a\":{\"b\":");
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, "[1,2]}}");
    try std.testing.expect(asmb.isComplete());
}

test "assembler ignores brackets inside strings" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"v\":\"{not a bracket}\"}");
    try std.testing.expect(asmb.isComplete());
}

test "assembler handles escaped quotes in strings" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"v\":\"say \\\"hi\\\"\"}");
    try std.testing.expect(asmb.isComplete());
}

test "assembler returns error for unmatched closing bracket" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    try std.testing.expectError(error.AssemblerInvalid, asmb.feed(std.testing.allocator, "}"));
}

test "assembler returns error after invalid state" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = asmb.feed(std.testing.allocator, "}") catch {};
    try std.testing.expectError(error.AssemblerInvalid, asmb.feed(std.testing.allocator, "{\"a\":1}"));
}

test "assembler reset allows reuse" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"a\":1}");
    try std.testing.expect(asmb.isComplete());
    asmb.reset();
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, "{\"b\":2}");
    try std.testing.expect(asmb.isComplete());
    try std.testing.expectEqualStrings("{\"b\":2}", asmb.slice());
}

test "assembler handles real Anthropic tool call chunks" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    // Simulated input_json_delta chunks
    _ = try asmb.feed(std.testing.allocator, "{\"");
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, "city\"");
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, ": \"San");
    try std.testing.expect(!asmb.isComplete());
    _ = try asmb.feed(std.testing.allocator, " Francisco\"}");
    try std.testing.expect(asmb.isComplete());
    try std.testing.expectEqualStrings("{\"city\": \"San Francisco\"}", asmb.slice());
}

test "assembler rejects feed after complete" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "{\"a\":1}");
    try std.testing.expectError(error.AssemblerInvalid, asmb.feed(std.testing.allocator, "more"));
}

test "assembler handles empty chunk" {
    var asmb = Assembler.init();
    defer asmb.deinit(std.testing.allocator);
    _ = try asmb.feed(std.testing.allocator, "");
    try std.testing.expectEqual(Assembler.State.empty, asmb.state);
}
