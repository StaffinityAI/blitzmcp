//! Implements an MCP server over stdio using `blitzmcp.Server`.
//!
//! Try it with the MCP Inspector:
//!
//! ```
//! zig build
//! npx @modelcontextprotocol/inspector zig-out/bin/stdio-server
//! ```

const std = @import("std");
const mcp = @import("blitzmcp");

pub fn main(init: std.process.Init) !void {
    // MCP servers communicate over stdio using newline-delimited JSON.
    // Logging must go to stderr, never stdout.
    var read_buffer: [4096]u8 = undefined;
    var stdio_transport: mcp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());

    var handler: Handler = .{};
    var server: Server = .init(&handler);
    try server.run(init.io, init.gpa, &stdio_transport.transport);
}

const Server = mcp.Server(Handler, .{
    .name = "blitz-example",
    .title = "Blitz MCP Example",
    .version = "0.1.0",
    .instructions = "A demo server with a counter, a word counter, a slow countdown, a summarizer and a greeting prompt.",
    // Each request is handled in its own task: slow tools do not block other
    // requests, they can be canceled, and handlers can send requests to the
    // client (see `summarize`). Handlers must be thread-safe.
    .concurrency = .concurrent,
    .tools = .{
        .{
            .name = "increment",
            .description = "Increments a counter and returns the new value.",
            .call = Handler.increment,
        },
        .{
            .name = "count_words",
            .title = "Count Words",
            .description = "Counts the words in a text.",
            .annotations = .{ .readOnlyHint = true, .openWorldHint = false },
            .call = Handler.countWords,
        },
        .{
            .name = "countdown",
            .description = "Counts down from a number, one step every 100 ms, reporting progress. Can be canceled.",
            .call = Handler.countdown,
        },
        .{
            .name = "summarize",
            .description = "Asks the client's LLM (via sampling) to summarize a text.",
            .call = Handler.summarize,
        },
    },
    .prompts = .{
        .{
            .name = "greet",
            .description = "Writes a greeting.",
            .call = Handler.greet,
        },
    },
});

const Handler = struct {
    /// Requests are handled concurrently, so the counter is protected by a mutex.
    mutex: std.Io.Mutex = .init,
    counter: i64 = 0,

    const IncrementArgs = struct {
        by: i64 = 1,

        pub const descriptions = .{ .by = "The amount to add to the counter." };
    };

    // Returning a struct produces both `structuredContent` and an `outputSchema`.
    fn increment(handler: *Handler, ctx: *mcp.Context, args: IncrementArgs) !struct { value: i64 } {
        try handler.mutex.lock(ctx.io);
        defer handler.mutex.unlock(ctx.io);
        handler.counter = std.math.add(i64, handler.counter, args.by) catch
            return ctx.fail(error.Overflow, "The counter would overflow", .{});
        return .{ .value = handler.counter };
    }

    const CountWordsArgs = struct {
        text: []const u8,

        pub const descriptions = .{ .text = "The text whose words should be counted." };
    };

    fn countWords(ctx: *mcp.Context, args: CountWordsArgs) ![]const u8 {
        if (args.text.len == 0) return ctx.fail(error.EmptyText, "The text must not be empty", .{});

        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, args.text, " \t\r\n");
        while (it.next()) |_| count += 1;

        // Only sent if the client asked for progress via `_meta.progressToken`.
        try ctx.sendProgress(1, 1, "done");
        try ctx.logf(.info, "counted {d} words", .{count});
        return std.fmt.allocPrint(ctx.arena, "{d}", .{count});
    }

    const CountdownArgs = struct {
        from: u8 = 5,

        pub const descriptions = .{ .from = "The number to count down from." };
    };

    fn countdown(ctx: *mcp.Context, args: CountdownArgs) ![]const u8 {
        var remaining = args.from;
        while (remaining > 0) : (remaining -= 1) {
            try ctx.sendProgress(@floatFromInt(args.from - remaining), @floatFromInt(args.from), null);
            // Returns `error.Canceled` when the client cancels the request.
            try ctx.io.sleep(.fromMilliseconds(100), .awake);
        }
        return "liftoff";
    }

    const SummarizeArgs = struct {
        text: []const u8,

        pub const descriptions = .{ .text = "The text to summarize." };
    };

    fn summarize(ctx: *mcp.Context, args: SummarizeArgs) ![]const u8 {
        const prompt = try std.fmt.allocPrint(ctx.arena, "Summarize in one sentence: {s}", .{args.text});
        // Waits for the client's response; fails if the client does not support sampling.
        const result = ctx.request("sampling/createMessage", .{
            .messages = &.{.{ .role = .user, .content = .initText(prompt) }},
            .maxTokens = 100,
        }) catch |err| switch (err) {
            error.CapabilityMissing => return ctx.fail(err, "The client does not support sampling", .{}),
            error.RequestFailed => return ctx.fail(err, "Sampling failed: {s}", .{ctx.response_error.?.message}),
            else => |e| return e,
        };
        return switch (result.content) {
            .text => |text| text.text,
            else => ctx.fail(error.UnexpectedContent, "The client returned non-text content", .{}),
        };
    }

    const GreetArgs = struct {
        name: []const u8,
        style: ?[]const u8 = null,

        pub const descriptions = .{
            .name = "Who to greet.",
            .style = "The style of the greeting, e.g. 'formal'.",
        };
    };

    fn greet(arena: std.mem.Allocator, args: GreetArgs) ![]const u8 {
        return std.fmt.allocPrint(arena, "Write a {s} greeting for {s}.", .{ args.style orelse "friendly", args.name });
    }

    // Protocol level methods can be implemented by declaring a function with the method name.
    pub fn @"resources/list"(_: *Handler) mcp.types.ListResourcesResult {
        return .{ .resources = &.{
            .{ .uri = "counter://value", .name = "counter", .mimeType = "text/plain" },
        } };
    }

    pub fn @"resources/read"(handler: *Handler, ctx: *mcp.Context, arena: std.mem.Allocator, params: mcp.types.ReadResourceRequestParams) !mcp.types.ReadResourceResult {
        if (!std.mem.eql(u8, params.uri, "counter://value")) return error.ResourceNotFound;
        try handler.mutex.lock(ctx.io);
        defer handler.mutex.unlock(ctx.io);
        const contents = try arena.alloc(mcp.types.ResourceContents, 1);
        contents[0] = .{ .text = .{
            .uri = params.uri,
            .mimeType = "text/plain",
            .text = try std.fmt.allocPrint(arena, "{d}", .{handler.counter}),
        } };
        return .{ .contents = contents };
    }
};
