const std = @import("std");
const escape_mod = @import("escape.zig");

pub const MAX_DEPTH = 64;

pub const WriteError = error{MaxDepthExceeded};

/// JSON writer generic over any writer type with writeAll/writeByte/print.
/// Handles comma insertion, string escaping, and nesting automatically.
pub fn JsonWriter(comptime WriterType: type) type {
    const ChildType = switch (@typeInfo(WriterType)) {
        .pointer => |p| p.child,
        else => WriterType,
    };
    return struct {
        writer: WriterType,
        depth: u8 = 0,
        nesting_stack: [MAX_DEPTH]Container = undefined,
        needs_comma: [MAX_DEPTH]bool = [_]bool{false} ** MAX_DEPTH,

        const Self = @This();
        const Container = enum { object, array };
        const Error = ChildType.Error || WriteError;

        pub fn init(writer: WriterType) Self {
            return .{ .writer = writer };
        }

        // --- Object methods ---

        /// Write a string key-value pair.
        pub fn string(self: *Self, key: []const u8, value: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.writeString(value);
        }

        /// Write a key with integer value.
        pub fn integer(self: *Self, key: []const u8, value: i64) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.writer.print("{d}", .{value});
        }

        /// Write a key with float value.
        pub fn float(self: *Self, key: []const u8, value: f64) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.writer.print("{d}", .{value});
        }

        /// Write a key with boolean value.
        pub fn boolean(self: *Self, key: []const u8, value: bool) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.writer.writeAll(if (value) "true" else "false");
        }

        /// Write a key with null value.
        pub fn nullValue(self: *Self, key: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeAll(":null");
        }

        /// Write a key with pre-serialized raw JSON value. Caller asserts validity.
        pub fn raw(self: *Self, key: []const u8, value: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.writer.writeAll(value);
        }

        /// Begin a nested object with the given key.
        pub fn beginObject(self: *Self, key: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.pushContainer(.object);
        }

        /// Begin a nested array with the given key.
        pub fn beginArray(self: *Self, key: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(key);
            try self.writer.writeByte(':');
            try self.pushContainer(.array);
        }

        // --- Array element methods ---

        /// Write a string element in an array.
        pub fn arrayString(self: *Self, value: []const u8) Error!void {
            try self.writeComma();
            try self.writeString(value);
        }

        /// Write an integer element in an array.
        pub fn arrayInt(self: *Self, value: i64) Error!void {
            try self.writeComma();
            try self.writer.print("{d}", .{value});
        }

        /// Write a boolean element in an array.
        pub fn arrayBool(self: *Self, value: bool) Error!void {
            try self.writeComma();
            try self.writer.writeAll(if (value) "true" else "false");
        }

        /// Write a null element in an array.
        pub fn arrayNull(self: *Self) Error!void {
            try self.writeComma();
            try self.writer.writeAll("null");
        }

        /// Write a raw JSON element in an array.
        pub fn arrayRaw(self: *Self, value: []const u8) Error!void {
            try self.writeComma();
            try self.writer.writeAll(value);
        }

        /// Begin a nested object element in an array.
        pub fn beginObjectElem(self: *Self) Error!void {
            try self.writeComma();
            try self.pushContainer(.object);
        }

        /// Begin a nested array element in an array.
        pub fn beginArrayElem(self: *Self) Error!void {
            try self.writeComma();
            try self.pushContainer(.array);
        }

        // --- Lifecycle ---

        /// Begin a top-level object. Call this first.
        pub fn beginTopObject(self: *Self) Error!void {
            try self.pushContainer(.object);
        }

        /// Begin a top-level array. Call this first.
        pub fn beginTopArray(self: *Self) Error!void {
            try self.pushContainer(.array);
        }

        /// End the current object or array.
        pub fn end(self: *Self) Error!void {
            std.debug.assert(self.depth > 0);
            self.depth -= 1;
            const c = self.nesting_stack[self.depth];
            try self.writer.writeByte(if (c == .object) '}' else ']');
        }

        // --- Internal ---

        fn writeComma(self: *Self) Error!void {
            if (self.depth > 0 and self.needs_comma[self.depth - 1]) {
                try self.writer.writeByte(',');
            }
            if (self.depth > 0) {
                self.needs_comma[self.depth - 1] = true;
            }
        }

        fn writeString(self: *Self, s: []const u8) Error!void {
            try self.writer.writeByte('"');
            try escape_mod.escape(self.writer, s);
            try self.writer.writeByte('"');
        }

        fn pushContainer(self: *Self, container: Container) Error!void {
            if (self.depth >= MAX_DEPTH) return error.MaxDepthExceeded;
            self.nesting_stack[self.depth] = container;
            self.needs_comma[self.depth] = false;
            self.depth += 1;
            try self.writer.writeByte(if (container == .object) '{' else '[');
        }
    };
}

/// Create a JsonWriter from any writer with writeAll/writeByte/print.
pub fn jsonWriter(writer: anytype) JsonWriter(@TypeOf(writer)) {
    return JsonWriter(@TypeOf(writer)).init(writer);
}

// --- Tests ---

var test_buf: [4096]u8 = undefined;
fn writeToString(comptime f: anytype) ![]const u8 {
    var writer = std.Io.Writer.fixed(&test_buf);
    var w = jsonWriter(&writer);
    try f(&w);
    return writer.buffered();
}

test "writer produces empty object" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings("{}", result);
}

test "writer produces key-value pair" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.string("name", "hello");
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"name":"hello"}
    , result);
}

test "writer handles multiple keys with commas" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.string("a", "1");
            try w.string("b", "2");
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"a":"1","b":"2"}
    , result);
}

test "writer escapes strings" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.string("msg", "hello \"world\"\nnewline");
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"msg":"hello \"world\"\nnewline"}
    , result);
}

test "writer handles boolean integer null" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.boolean("stream", true);
            try w.integer("count", 42);
            try w.nullValue("extra");
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"stream":true,"count":42,"extra":null}
    , result);
}

test "writer handles nested object" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.beginObject("delta");
            try w.string("content", "hi");
            try w.end();
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"delta":{"content":"hi"}}
    , result);
}

test "writer handles array" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.beginArray("items");
            try w.arrayString("a");
            try w.arrayString("b");
            try w.end();
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"items":["a","b"]}
    , result);
}

test "writer handles array of objects" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.beginArray("messages");
            try w.beginObjectElem();
            try w.string("role", "user");
            try w.string("content", "hi");
            try w.end();
            try w.end();
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"messages":[{"role":"user","content":"hi"}]}
    , result);
}

test "writer raw passthrough" {
    const tools_json =
        \\[{"type":"function","function":{"name":"get_weather"}}]
    ;
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.string("model", "claude-sonnet-4");
            try w.raw("tools", tools_json);
            try w.end();
        }
    }.f);
    try std.testing.expectEqualStrings(
        \\{"model":"claude-sonnet-4","tools":[{"type":"function","function":{"name":"get_weather"}}]}
    , result);
}

test "writer output parses with std.json" {
    const result = try writeToString(struct {
        fn f(w: anytype) !void {
            try w.beginTopObject();
            try w.string("model", "test");
            try w.boolean("stream", true);
            try w.beginArray("messages");
            try w.beginObjectElem();
            try w.string("role", "user");
            try w.string("content", "hello");
            try w.end();
            try w.end();
            try w.integer("max_tokens", 1024);
            try w.end();
        }
    }.f);

    // Verify it parses correctly with std.json
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("test", obj.get("model").?.string);
    try std.testing.expect(obj.get("stream").?.bool);
    try std.testing.expectEqual(@as(i64, 1024), obj.get("max_tokens").?.integer);
}
