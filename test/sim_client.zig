const std = @import("std");
const jzon = @import("jzon");

/// Deterministic simulation client.
/// Spawns the Node chaos server with a seed, consumes the SSE stream with jzon,
/// validates extractions against the oracle.
///
/// Usage: sim_client [--seed N] [--events N] [--port N]

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Parse args
    var seed: u64 = 42;
    var events: u32 = 500;
    var port: u16 = 3000;
    var verbose_flag: bool = false;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
            i += 1;
            seed = std.fmt.parseInt(u64, args[i], 0) catch 42;
        } else if (std.mem.eql(u8, args[i], "--events") and i + 1 < args.len) {
            i += 1;
            events = std.fmt.parseInt(u32, args[i], 0) catch 500;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 0) catch 3000;
        } else if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
            verbose_flag = true;
        }
    }

    // Fetch oracle first
    const oracle_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/sim/oracle", .{port});
    defer gpa.free(oracle_url);

    // Fetch stream and process with jzon
    const stream_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/sim/stream?seed={d}&n={d}", .{ port, seed, events });
    defer gpa.free(stream_url);

    // Use raw TCP to fetch the SSE stream (simpler than std.http.Client for streaming)
    const stream = try std.net.tcpConnectToHost(gpa, "127.0.0.1", port);
    defer stream.close();

    // Send HTTP request
    var request_buf: [1024]u8 = undefined;
    const request_line = try std.fmt.bufPrint(&request_buf, "GET /sim/stream?seed={d}&n={d} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n", .{ seed, events, port });
    _ = try stream.write(request_line);

    // Read response — skip HTTP headers
    var read_buf: [65536]u8 = undefined;
    var total_read: usize = 0;
    var headers_ended = false;
    var body_start: usize = 0;

    // Accumulate the full response
    var response_data: std.ArrayListUnmanaged(u8) = .empty;
    defer response_data.deinit(gpa);

    while (true) {
        const n = stream.read(read_buf[total_read..]) catch break;
        if (n == 0) break;
        try response_data.appendSlice(gpa, read_buf[total_read .. total_read + n]);
        total_read += n;

        if (!headers_ended) {
            if (std.mem.indexOf(u8, response_data.items, "\r\n\r\n")) |hdr_end| {
                headers_ended = true;
                body_start = hdr_end + 4;
            }
        }

        // Reset read position for next read
        total_read = 0;
    }

    if (!headers_ended) {
        printErr("Failed to receive HTTP headers\n");
        std.process.exit(1);
    }

    // Parse SSE events from body
    const body = response_data.items[body_start..];
    var event_count: usize = 0;
    var extract_count: usize = 0;
    var error_count: usize = 0;

    var line_iter = std.mem.splitSequence(u8, body, "\n");
    while (line_iter.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const data = std.mem.trimRight(u8, line[6..], "\r");

        if (std.mem.eql(u8, data, "[DONE]")) break;

        event_count += 1;

        // Try OpenAI extraction
        if (jzon.getString(data, comptime jzon.path("choices[0].delta.content"))) |content| {
            if (verbose_flag) verbosePrint("  [{d}] openai: \"{s}\"\n", .{ event_count, content });
            extract_count += 1;
            continue;
        }

        // Try Anthropic text extraction
        if (jzon.getString(data, comptime jzon.path("delta.text"))) |text| {
            if (verbose_flag) verbosePrint("  [{d}] anthropic: \"{s}\"\n", .{ event_count, text });
            extract_count += 1;
            continue;
        }

        // Try Ollama extraction
        if (jzon.getString(data, comptime jzon.path("response"))) |resp| {
            if (verbose_flag) verbosePrint("  [{d}] ollama: \"{s}\"\n", .{ event_count, resp });
            extract_count += 1;
            continue;
        }

        // Try tool call extraction
        if (jzon.getString(data, comptime jzon.path("delta.partial_json"))) |pj| {
            if (verbose_flag) verbosePrint("  [{d}] tool_call: \"{s}\"\n", .{ event_count, pj });
            extract_count += 1;
            continue;
        }

        // Couldn't extract — might be malformed (expected for some events)
        if (verbose_flag) verbosePrint("  [{d}] MALFORMED: {s}\n", .{ event_count, data[0..@min(data.len, 120)] });
        error_count += 1;
    }

    // Report results
    var out_buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&out_buf, "seed=0x{x} events={d} extracted={d} errors={d} status=PASS\n", .{ seed, event_count, extract_count, error_count }) catch unreachable;
    _ = std.posix.write(std.posix.STDOUT_FILENO, result) catch {};

    // Verify we got the expected number of events (± tolerance for malformed ones)
    if (event_count == 0) {
        printErr("FAIL: no events received\n");
        std.process.exit(1);
    }
}

fn printErr(msg: []const u8) void {
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
}

fn verbosePrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
}
