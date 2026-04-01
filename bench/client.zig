const std = @import("std");
const jzon = @import("jzon");

const WARMUP = 1000;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const iterations = getIterations();

    // Load payloads from JSON file
    const payloads_bytes = try loadFile(gpa, "bench/payloads.json");
    defer gpa.free(payloads_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, payloads_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Extract payload strings
    const openai_chunks = try extractStringArray(gpa, root.get("openai_chunks").?.array);
    defer {
        for (openai_chunks) |s| gpa.free(s);
        gpa.free(openai_chunks);
    }

    const tool_fragments = try extractStringArray(gpa, root.get("tool_call_fragments").?.array);
    defer {
        for (tool_fragments) |s| gpa.free(s);
        gpa.free(tool_fragments);
    }

    const fields = root.get("request_fields").?.object;
    const model = fields.get("model").?.string;
    const max_tokens_val = fields.get("max_tokens").?.integer;
    const user_message = fields.get("user_message").?.string;
    const tools_json = fields.get("tools_json").?.string;

    // --- Benchmark 1: Path extraction ---
    {
        var sink: usize = 0;
        const ops = iterations * openai_chunks.len;

        // Warmup
        for (0..WARMUP) |_| {
            for (openai_chunks) |chunk| {
                const result = jzon.getString(chunk, comptime jzon.path("choices[0].delta.content"));
                if (result) |r| sink += r.len;
            }
        }

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            for (openai_chunks) |chunk| {
                const result = jzon.getString(chunk, comptime jzon.path("choices[0].delta.content"));
                if (result) |r| sink += r.len;
            }
        }
        const elapsed_ns = timer.read();

        std.mem.doNotOptimizeAway(&sink);
        try report("path_extract", ops, elapsed_ns);
    }

    // --- Benchmark 2: Tool call assembly ---
    {
        var sink: usize = 0;

        // Warmup
        for (0..WARMUP) |_| {
            var asmb = jzon.Assembler.init();
            for (tool_fragments) |frag| {
                _ = asmb.feed(gpa, frag) catch break;
            }
            if (asmb.isComplete()) sink += asmb.slice().len;
            asmb.deinit(gpa);
        }

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var asmb = jzon.Assembler.init();
            for (tool_fragments) |frag| {
                _ = asmb.feed(gpa, frag) catch break;
            }
            if (asmb.isComplete()) sink += asmb.slice().len;
            asmb.deinit(gpa);
        }
        const elapsed_ns = timer.read();

        std.mem.doNotOptimizeAway(&sink);
        try report("tool_assembly", iterations, elapsed_ns);
    }

    // --- Benchmark 3: Request building ---
    {
        var sink: usize = 0;

        // Warmup
        for (0..WARMUP) |_| {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var w = jzon.jsonWriter(fbs.writer());
            try w.beginTopObject();
            try w.string("model", model);
            try w.integer("max_tokens", max_tokens_val);
            try w.boolean("stream", true);
            try w.beginArray("messages");
            try w.beginObjectElem();
            try w.string("role", "user");
            try w.string("content", user_message);
            try w.end();
            try w.end();
            try w.raw("tools", tools_json);
            try w.end();
            sink += fbs.pos;
        }

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var buf: [4096]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            var w = jzon.jsonWriter(fbs.writer());
            try w.beginTopObject();
            try w.string("model", model);
            try w.integer("max_tokens", max_tokens_val);
            try w.boolean("stream", true);
            try w.beginArray("messages");
            try w.beginObjectElem();
            try w.string("role", "user");
            try w.string("content", user_message);
            try w.end();
            try w.end();
            try w.raw("tools", tools_json);
            try w.end();
            sink += fbs.pos;
        }
        const elapsed_ns = timer.read();

        std.mem.doNotOptimizeAway(&sink);
        try report("request_build", iterations, elapsed_ns);
    }
}

fn report(bench: []const u8, iterations: usize, elapsed_ns: u64) !void {
    const total_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ops_per_sec: u64 = if (elapsed_ns > 0)
        @intFromFloat(@as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0))
    else
        0;

    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf,
        \\{{"lang":"zig","bench":"{s}","iterations":{d},"total_ms":{d:.2},"ops_per_sec":{d},"peak_rss_kb":0}}
    ++ "\n", .{ bench, iterations, total_ms, ops_per_sec }) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
}

fn getIterations() usize {
    const env = std.posix.getenv("BENCH_ITERATIONS") orelse return 100000;
    return std.fmt.parseInt(usize, env, 10) catch 100000;
}

fn loadFile(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(rel_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn extractStringArray(allocator: std.mem.Allocator, array: std.json.Array) ![][]u8 {
    var result = try allocator.alloc([]u8, array.items.len);
    for (array.items, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item.string);
    }
    return result;
}
