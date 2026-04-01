const std = @import("std");
const jzon = @import("jzon");

/// SSE streaming benchmark — measures the full pipeline:
/// connect → read TCP → split SSE lines → jzon.getString() → extract content
///
/// Usage: stream_client [--port N] [--events N] [--provider openai|anthropic|ollama]

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var port: u16 = 3000;
    var events: u32 = 10000;
    var provider: []const u8 = "openai";

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 0) catch 3000;
        } else if (std.mem.eql(u8, args[i], "--events") and i + 1 < args.len) {
            i += 1;
            events = std.fmt.parseInt(u32, args[i], 0) catch 10000;
        } else if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
            i += 1;
            provider = args[i];
        }
    }

    // Connect to server
    const stream = try std.net.tcpConnectToHost(gpa, "127.0.0.1", port);
    defer stream.close();

    // Send HTTP request
    var req_buf: [512]u8 = undefined;
    const path_str = if (std.mem.eql(u8, provider, "anthropic"))
        "/anthropic/stream"
    else if (std.mem.eql(u8, provider, "ollama"))
        "/ollama/stream"
    else
        "/openai/stream";

    const request_line = try std.fmt.bufPrint(&req_buf, "GET {s}?n={d} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n", .{ path_str, events, port });

    var timer = try std.time.Timer.start();
    _ = try stream.write(request_line);

    // Read and parse SSE stream
    var read_buf: [65536]u8 = undefined;
    var line_buf: [8192]u8 = undefined;
    var line_len: usize = 0;
    var headers_ended = false;
    var event_count: usize = 0;
    var extract_count: usize = 0;
    var done = false;

    while (!done) {
        const n = stream.read(&read_buf) catch break;
        if (n == 0) break;

        var chunk_pos: usize = 0;
        while (chunk_pos < n) {
            const byte = read_buf[chunk_pos];
            chunk_pos += 1;

            if (!headers_ended) {
                // Accumulate until we see \r\n\r\n
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
                if (line_len >= 4 and
                    line_buf[line_len - 4] == '\r' and
                    line_buf[line_len - 3] == '\n' and
                    line_buf[line_len - 2] == '\r' and
                    line_buf[line_len - 1] == '\n')
                {
                    headers_ended = true;
                    line_len = 0;
                }
                continue;
            }

            // Accumulate line
            if (byte == '\n') {
                const line = line_buf[0..line_len];
                // Trim \r
                const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
                    line[0 .. line.len - 1]
                else
                    line;

                if (std.mem.startsWith(u8, trimmed, "data: ")) {
                    const data = trimmed[6..];
                    if (std.mem.eql(u8, data, "[DONE]")) {
                        done = true;
                        break;
                    }

                    event_count += 1;

                    // Extract based on provider
                    if (std.mem.eql(u8, provider, "openai")) {
                        if (jzon.getString(data, comptime jzon.path("choices[0].delta.content"))) |_| {
                            extract_count += 1;
                        }
                    } else if (std.mem.eql(u8, provider, "anthropic")) {
                        if (jzon.getString(data, comptime jzon.path("delta.text"))) |_| {
                            extract_count += 1;
                        }
                    } else {
                        if (jzon.getString(data, comptime jzon.path("response"))) |_| {
                            extract_count += 1;
                        }
                    }
                }

                line_len = 0;
            } else {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = byte;
                    line_len += 1;
                }
            }
        }
    }

    const elapsed_ns = timer.read();
    const total_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const events_per_sec: u64 = if (elapsed_ns > 0)
        @intFromFloat(@as(f64, @floatFromInt(event_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0))
    else
        0;

    var out_buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&out_buf,
        \\{{"lang":"zig","bench":"sse_{s}","events":{d},"extracted":{d},"total_ms":{d:.2},"events_per_sec":{d}}}
    ++ "\n", .{ provider, event_count, extract_count, total_ms, events_per_sec }) catch unreachable;
    _ = std.posix.write(std.posix.STDOUT_FILENO, result) catch {};
}
