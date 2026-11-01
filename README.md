[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# blitzmcp

Building blocks for [Model Context Protocol](https://modelcontextprotocol.io/specification/2025-11-25) servers in Zig.

Derived from [zigtools/lsp-kit](https://github.com/zigtools/lsp-kit). The JSON-RPC envelope, the `Transport` abstraction and the comptime dispatch pattern were kept; everything specific to the Language Server Protocol was removed.

| Module                         | Purpose                                                                                      |
| ------------------------------ | -------------------------------------------------------------------------------------------- |
| `json_rpc`                     | JSON-RPC 2.0 messages (`JsonRPCMessage`, `ID`, typed request/notification/response writers) |
| `Transport`                    | Type-erased message transport. `Transport.Stdio` uses newline-delimited JSON, `Transport.Stream` wraps any `std.Io.Reader`/`std.Io.Writer` |
| `types`                        | Hand-written MCP protocol types (lifecycle, tools, resources, prompts, logging, sampling, elicitation, …) and method tables |
| `schema`                       | Comptime JSON Schema generation from Zig types                                               |
| `Server` / `Context`           | Server loop with comptime two-level dispatch                                                 |

# Installation

> [!NOTE]
> Requires Zig `0.17.0` or later.

```bash
zig fetch --save git+https://github.com/StaffinityAI/blitzmcp.git
```

```zig
const blitzmcp = b.dependency("blitzmcp", .{}).module("blitzmcp");
exe.root_module.addImport("blitzmcp", blitzmcp);
```

# Usage

```zig
const std = @import("std");
const mcp = @import("blitzmcp");

const Server = mcp.Server(Handler, .{
    .name = "my-zig-mcp",
    .version = "0.1.0",
    .tools = .{
        .{
            .name = "search_files",
            .description = "Search files in workspace",
            .annotations = .{ .readOnlyHint = true },
            .call = Handler.searchFiles,
        },
    },
});

const Handler = struct {
    const SearchArgs = struct {
        query: []const u8,
        limit: u32 = 20,

        pub const descriptions = .{ .query = "The text to search for" };
    };

    // The input schema is generated from `SearchArgs` at comptime.
    fn searchFiles(handler: *Handler, ctx: *mcp.Context, args: SearchArgs) ![]const u8 {
        try ctx.sendProgress(0, null, "searching");
        ...
    }

    // Protocol level methods are implemented by declaring a function with the method name.
    pub fn @"resources/read"(handler: *Handler, arena: std.mem.Allocator, params: mcp.types.ReadResourceRequestParams) !mcp.types.ReadResourceResult {
        ...
    }
};

pub fn main(init: std.process.Init) !void {
    var read_buffer: [4096]u8 = undefined;
    var stdio: mcp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());

    var handler: Handler = .{};
    var server: Server = .init(&handler);
    try server.run(init.io, init.gpa, &stdio.transport);
}
```

- `initialize`, `ping`, `logging/setLevel`, `tools/list`, `tools/call`, `prompts/list` and `prompts/get` are handled by the server. Server capabilities are derived from the config and the methods the `Handler` declares.
- Handler functions request their arguments by type: the handler (`*Handler`), an arena (`std.mem.Allocator`), the request context (`*mcp.Context`) and the parsed params/arguments.
- Tool errors (including invalid arguments) are returned as a `CallToolResult` with `isError = true`. Errors from protocol level methods become JSON-RPC errors (`error.InvalidParams` → `-32602`, `error.ResourceNotFound` → `-32002`, …).
- Tools that return a struct produce `structuredContent` and an `outputSchema`.
- Optional fields of tool and prompt arguments must have a default (e.g. `?u32 = null`); this is enforced at compile time.
- Results and notifications are checked before sending: non-finite floats and text that is not valid UTF-8 are reported as errors instead of producing invalid JSON.
- `Server.handleMessage` is independent of the framing so that it can be reused by other transports.
- Requests other than `initialize` and `ping` are rejected until the server has answered `initialize`.
- Messages larger than `max_message_len` (16 MiB by default) are skipped and answered with an error, and running out of memory while handling a request is reported to the client instead of stopping the server.

> [!NOTE]
> The MCP TypeScript SDK client (tested with 1.32.2) runs notification handlers in a microtask but handles responses synchronously. If a progress notification arrives in the same read as its response, the client drops it with "unknown token", even though the server sent it first. This affects any MCP server, not only this library.

See [`examples/stdio_server.zig`](examples/stdio_server.zig) for a complete server. Try it with the MCP Inspector:

```bash
zig build
npx @modelcontextprotocol/inspector zig-out/bin/stdio-server
```

## Concurrency, cancellation and requests to the client

With `.concurrency = .concurrent` in the server config, every request is handled in its own `std.Io` task:

- Slow requests do not block others (including `ping`). At most `.max_concurrent_requests` (default 64) run at once; further requests get a JSON-RPC error.
- `notifications/cancelled` cancels a request: its handler receives `error.Canceled` from its next `Io` call (e.g. `ctx.io.sleep`, a file read or `ctx.request`) and no response is sent. `ctx.isCanceled()` lets CPU-bound handlers check.
- Handlers can send requests to the client and wait for the response:

  ```zig
  const result = try ctx.request("sampling/createMessage", .{
      .messages = &.{.{ .role = .user, .content = .initText("Summarize ...") }},
      .maxTokens = 100,
  });
  ```

  `ctx.request` checks the capabilities the client declared (`error.CapabilityMissing`), reports the client's error response via `error.RequestFailed` and `ctx.response_error`, and forwards cancelation to the client.

Handlers must be thread-safe in this mode, e.g. protect shared state with a `std.Io.Mutex`. It needs an `Io` implementation with concurrency such as `std.Io.Threaded` (what `std.process.Init` provides); otherwise requests are handled one after another. The default, `.concurrency = .serial`, handles one message at a time, and `ctx.request` returns `error.RequestsUnavailable`. See `examples/stdio_server.zig`.

# Development

```bash
zig build test   # unit tests
zig build e2e    # end-to-end tests: the official MCP TypeScript SDK client drives examples/stdio_server.zig (requires Node.js and npm)
zig build ci     # everything CI runs: format check, unit tests, build, docs and e2e tests
zig build ci -Doptimize=ReleaseSafe  # CI also runs everything in ReleaseSafe
zig build test --fuzz=30K -Duse-llvm  # fuzz the message handler, the NDJSON reader and the result checks
```

The fuzz targets are the tests named `fuzz …` (`fuzz handleMessage`, `fuzz readNdjsonMessage`, `fuzz checkJson`); `--fuzz` is not supported on Windows, and needs `-Duse-llvm` on x86_64 (the self-hosted backend emits no coverage instrumentation). CI fuzzes them with a new `--seed` for every run. `zig build test --fuzz` exits with code 0 even when it finds a failing input, so check for `.zig-cache/f/crash`, which contains the input (CI uploads it as the `fuzz-crash` artifact). To reproduce a failure and keep it as a regression test, add the file (via `@embedFile`) to the `corpus` of the failing `std.testing.fuzz` call; `zig build test` always runs the corpus.

