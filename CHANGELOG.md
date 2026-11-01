# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0.0, minor versions may contain breaking changes.

## [Unreleased]

## [0.1.0] - 2026-11-01

First release. Building blocks for [Model Context Protocol](https://modelcontextprotocol.io/specification/2025-11-25) servers (spec 2025-11-25) in Zig 0.17, derived from [zigtools/lsp-kit](https://github.com/zigtools/lsp-kit).

### Added

- `json_rpc`: JSON-RPC 2.0 messages (`JsonRPCMessage`, `ID`, typed request, notification and response writers), including the MCP error codes `-32002` (resource not found) and `-32042` (URL elicitation required).
- `Transport`: type-erased message transport with newline-delimited JSON framing. `Transport.Stdio` for stdio servers, `Transport.Stream` for any `std.Io.Reader`/`std.Io.Writer`, `Transport.Channel` for in-memory connections, and `Transport.ThreadSafe`. Messages larger than `max_message_len` (16 MiB by default) are skipped.
- `types`: hand-written MCP protocol types (lifecycle, tools, resources, prompts, completion, logging, sampling, elicitation, roots, progress, cancellation) and method tables.
- `schema`: comptime JSON Schema generation from Zig types, including field descriptions, tagged unions and custom `json_schema` declarations.
- `Server` / `Context`: server loop with comptime two-level dispatch.
  - Handles `initialize`, `ping`, `logging/setLevel`, `tools/list`, `tools/call`, `prompts/list` and `prompts/get`; other methods are implemented by declaring a handler function with the method name. Server capabilities are derived from the config and the handler.
  - Tool and prompt arguments are parsed into Zig structs, and their input and output schemas are generated at comptime.
  - Enforces the lifecycle: requests other than `initialize` and `ping` are rejected until the server has answered `initialize`.
  - Results and notifications are checked before sending (non-finite numbers, invalid UTF-8, nesting depth), and running out of memory is reported to the client instead of stopping the server.
  - `Context` sends progress, log messages and notifications.
  - `.concurrency = .concurrent` handles each request in its own `std.Io` task, with a limit on concurrent requests (`.max_concurrent_requests`), cancellation via `notifications/cancelled`, a shutdown timeout and requests to the client (`ctx.request`, e.g. sampling or elicitation).
- `examples/stdio_server.zig`: example server with tools, a prompt, resources, progress, cancellation and sampling.
- `zig build ci`: format check, unit tests, build, docs and end-to-end tests against the official MCP TypeScript SDK client. CI runs it on Linux, macOS and Windows, and fuzzes the message handler, the NDJSON reader and the result checks.

[Unreleased]: https://github.com/StaffinityAI/blitzmcp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/StaffinityAI/blitzmcp/releases/tag/v0.1.0
