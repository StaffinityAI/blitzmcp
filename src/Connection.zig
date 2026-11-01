//! State of one client connection: the lifecycle state and, when requests are
//! handled concurrently, the requests in flight in both directions. Shared by
//! the tasks that handle requests of the connection.

const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const types = @import("types.zig");

const Connection = @This();

pub const Mode = enum {
    /// Messages are handled one after another by the task that reads them.
    serial,
    /// Requests are handled concurrently; see `Server`.
    concurrent,
};

/// The capabilities of the client that the server relies on.
pub const ClientCapabilities = struct {
    sampling: bool = false,
    elicitation: bool = false,
    roots: bool = false,
};

/// Tracks a request from the client that is being handled concurrently.
pub const InFlight = struct {
    /// The request's id. Its memory must stay valid while `registered`.
    id: json_rpc.ID,
    /// Whether the request is in `Connection.in_flight`. Only accessed by the
    /// task that handles the request (and its owner after it finished).
    registered: bool = false,
    /// Set when the handler finished or the client canceled the request.
    done: std.Io.Event = .unset,
    canceled: std.atomic.Value(bool) = .init(false),
};

/// A request to the client that is waiting for its response.
pub const Pending = struct {
    /// Set when the response arrived, could not be stored, or the connection
    /// was closed.
    done: std.Io.Event = .unset,
    /// The response message, allocated with `Connection.gpa`. `null` if the
    /// connection was closed before the response arrived or if the response
    /// could not be stored (`out_of_memory`).
    response: ?[]u8 = null,
    out_of_memory: bool = false,
};

pub const State = enum(u8) { not_initialized, initializing, initialized };

/// Allocates the bookkeeping of requests in flight and responses from the client.
gpa: std.mem.Allocator = undefined,

/// Requests other than `initialize` and `ping` are rejected until `initialized`.
state: std.atomic.Value(State) = .init(.not_initialized),
/// Written before `state` becomes `initialized` and only read after that.
client_capabilities: ClientCapabilities = .{},
/// The minimum log level requested via `logging/setLevel`, `no_log_level` if unset.
log_level: std.atomic.Value(u8) = .init(no_log_level),

/// Numbers the ids of requests to the client, see `requestId`.
next_request_id: std.atomic.Value(u64) = .init(1),

/// Guards `in_flight`, `pending`, `closed` and `idle`.
mutex: std.Io.Mutex = .init,
in_flight: std.HashMapUnmanaged(json_rpc.ID, *InFlight, IdContext, std.hash_map.default_max_load_percentage) = .empty,
pending: std.AutoHashMapUnmanaged(u64, *Pending) = .empty,
/// Whether the client went away. No more responses will arrive.
closed: bool = false,
/// Set while no request is in flight.
idle: std.Io.Event = .is_set,

const no_log_level = std.math.maxInt(u8);

/// Ids of requests to the client are strings with this prefix, so that they
/// cannot be confused with ids the `Handler` uses for its own requests.
pub const request_id_prefix = "blitzmcp-";

const IdContext = struct {
    pub fn hash(_: IdContext, id: json_rpc.ID) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        switch (id) {
            .number => |number| {
                hasher.update("n");
                hasher.update(std.mem.asBytes(&number));
            },
            .string => |string| {
                hasher.update("s");
                hasher.update(string);
            },
        }
        return hasher.final();
    }

    pub fn eql(_: IdContext, a: json_rpc.ID, b: json_rpc.ID) bool {
        return a.eql(b);
    }
};

/// Resets the connection for another session, e.g. before `Server.run` is
/// called again. Asserts that no requests are in flight in either direction.
pub fn reset(c: *Connection) void {
    std.debug.assert(c.in_flight.count() == 0 and c.pending.count() == 0);
    c.in_flight.deinit(c.gpa);
    c.pending.deinit(c.gpa);
    c.in_flight = .empty;
    c.pending = .empty;
    c.closed = false;
    c.state.store(.not_initialized, .release);
    c.client_capabilities = .{};
    c.log_level.store(no_log_level, .release);
}

pub fn logLevel(c: *const Connection) ?types.LoggingLevel {
    const level = c.log_level.load(.acquire);
    return if (level == no_log_level) null else @fromBackingInt(@intCast(level));
}

pub fn setLogLevel(c: *Connection, level: types.LoggingLevel) void {
    c.log_level.store(@backingInt(level), .release);
}

/// Claims the handling of `initialize`. Returns `false` if the connection is
/// already initialized or another `initialize` is being handled.
pub fn beginInitialize(c: *Connection) bool {
    return c.state.cmpxchgStrong(.not_initialized, .initializing, .acq_rel, .acquire) == null;
}

/// Undoes `beginInitialize` if `markInitialized` was not called.
pub fn abortInitialize(c: *Connection) void {
    _ = c.state.cmpxchgStrong(.initializing, .not_initialized, .acq_rel, .acquire);
}

/// Records the client's capabilities and accepts requests from now on. Also
/// usable for a session that was initialized elsewhere.
pub fn markInitialized(c: *Connection, params: types.InitializeRequestParams) void {
    c.client_capabilities = .{
        .sampling = params.capabilities.sampling != null,
        .elicitation = params.capabilities.elicitation != null,
        .roots = params.capabilities.roots != null,
    };
    c.state.store(.initialized, .release);
}

pub fn isInitialized(c: *const Connection) bool {
    return c.state.load(.acquire) == .initialized;
}

pub const RegisterError = std.mem.Allocator.Error || error{
    /// A request with the same id is still in flight.
    DuplicateId,
    /// `limit` requests are already in flight.
    TooManyRequests,
};

/// Registers a request from the client. `in_flight` (including the memory of
/// its id) must stay valid until `removeInFlight` is called.
pub fn addInFlight(c: *Connection, io: std.Io, in_flight: *InFlight, limit: usize) RegisterError!void {
    std.debug.assert(!in_flight.registered);
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.in_flight.count() >= limit) return error.TooManyRequests;
    const entry = try c.in_flight.getOrPut(c.gpa, in_flight.id);
    if (entry.found_existing) return error.DuplicateId;
    entry.value_ptr.* = in_flight;
    in_flight.registered = true;
    c.idle.reset();
}

/// Unregisters a request, e.g. just before its response is written, so that
/// the client can reuse its id and slot as soon as it has the response.
pub fn removeInFlight(c: *Connection, io: std.Io, in_flight: *InFlight) void {
    if (!in_flight.registered) return;
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    _ = c.in_flight.remove(in_flight.id);
    in_flight.registered = false;
    if (c.in_flight.count() == 0) c.idle.set(io);
}

/// Handles `notifications/cancelled` from the client. Unknown ids are ignored,
/// the request may already have finished.
pub fn cancelInFlight(c: *Connection, io: std.Io, id: json_rpc.ID) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    const in_flight = c.in_flight.get(id) orelse return;
    in_flight.canceled.store(true, .release);
    in_flight.done.set(io);
}

/// Registers a request to the client and returns its number, see `requestId`.
/// `pending` must stay valid until `removePending` is called.
pub fn addPending(c: *Connection, io: std.Io, pending: *Pending) (std.mem.Allocator.Error || error{ConnectionClosed})!u64 {
    const number = c.next_request_id.fetchAdd(1, .monotonic);
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.closed) return error.ConnectionClosed;
    try c.pending.put(c.gpa, number, pending);
    return number;
}

/// The id of the request to the client with the given number.
pub fn requestId(buffer: *[request_id_prefix.len + 20]u8, number: u64) json_rpc.ID {
    return .{ .string = std.fmt.bufPrint(buffer, request_id_prefix ++ "{d}", .{number}) catch unreachable };
}

pub fn removePending(c: *Connection, io: std.Io, number: u64) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    _ = c.pending.remove(number);
}

/// Hands a response from the client to the request waiting for it. Returns
/// `false` if the response does not belong to a request sent with
/// `addPending`.
pub fn deliverResponse(c: *Connection, io: std.Io, id: json_rpc.ID, json_message: []const u8) bool {
    const string = switch (id) {
        .string => |string| string,
        .number => return false,
    };
    if (!std.mem.startsWith(u8, string, request_id_prefix)) return false;
    const number = std.fmt.parseUnsigned(u64, string[request_id_prefix.len..], 10) catch return false;

    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    const pending = c.pending.get(number) orelse return false;
    if (pending.done.isSet()) return true; // duplicate response
    // Wake the waiting request even if the response cannot be stored.
    defer pending.done.set(io);
    pending.response = c.gpa.dupe(u8, json_message) catch {
        pending.out_of_memory = true;
        return true;
    };
    return true;
}

/// Marks the connection as closed: requests waiting for a response are woken
/// up and fail.
pub fn close(c: *Connection, io: std.Io) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    c.closed = true;
    var it = c.pending.valueIterator();
    while (it.next()) |pending| pending.*.done.set(io);
}

test "in flight requests" {
    const io = std.testing.io;
    var c: Connection = .{ .gpa = std.testing.allocator };
    defer c.reset();

    var a: InFlight = .{ .id = .{ .number = 1 } };
    var a_again: InFlight = .{ .id = .{ .number = 1 } };
    var b: InFlight = .{ .id = .{ .string = "1" } };
    try c.addInFlight(io, &a, 2);
    try std.testing.expect(!c.idle.isSet());
    try std.testing.expectError(error.DuplicateId, c.addInFlight(io, &a_again, 2));
    try c.addInFlight(io, &b, 2);
    var d: InFlight = .{ .id = .{ .number = 2 } };
    try std.testing.expectError(error.TooManyRequests, c.addInFlight(io, &d, 2));

    c.cancelInFlight(io, .{ .string = "1" });
    try std.testing.expect(b.canceled.load(.acquire) and b.done.isSet());
    try std.testing.expect(!a.canceled.load(.acquire));
    c.cancelInFlight(io, .{ .number = 42 }); // unknown

    c.removeInFlight(io, &a);
    try std.testing.expect(!c.idle.isSet());
    c.removeInFlight(io, &b);
    c.removeInFlight(io, &b); // no-op
    try std.testing.expect(c.idle.isSet());
    try std.testing.expectEqual(0, c.in_flight.count());

    // The id can be reused once the request was removed.
    try c.addInFlight(io, &a_again, 2);
    c.removeInFlight(io, &a_again);
}

test "pending requests" {
    const io = std.testing.io;
    var c: Connection = .{ .gpa = std.testing.allocator };
    defer c.reset();

    var pending: Pending = .{};
    const number = try c.addPending(io, &pending);
    var buffer: [request_id_prefix.len + 20]u8 = undefined;
    const id = requestId(&buffer, number);
    try std.testing.expectEqualStrings("blitzmcp-1", id.string);

    // Ids the handler might use for its own requests are not taken.
    try std.testing.expect(!c.deliverResponse(io, .{ .number = @intCast(number) }, "{}"));
    try std.testing.expect(!c.deliverResponse(io, .{ .string = "blitzmcp-x" }, "{}"));
    try std.testing.expect(c.deliverResponse(io, id, "{\"x\":1}"));
    try std.testing.expect(pending.done.isSet());
    try std.testing.expectEqualStrings("{\"x\":1}", pending.response.?);
    std.testing.allocator.free(pending.response.?);
    c.removePending(io, number);

    var other: Pending = .{};
    const other_number = try c.addPending(io, &other);
    c.close(io);
    try std.testing.expect(other.done.isSet() and other.response == null);
    c.removePending(io, other_number);
    var late: Pending = .{};
    try std.testing.expectError(error.ConnectionClosed, c.addPending(io, &late));
}

test "lifecycle and reset" {
    var c: Connection = .{ .gpa = std.testing.allocator };
    try std.testing.expect(c.beginInitialize());
    try std.testing.expect(!c.beginInitialize()); // a concurrent second `initialize`
    try std.testing.expect(!c.isInitialized());
    c.abortInitialize();
    try std.testing.expect(c.beginInitialize());
    c.markInitialized(.{ .protocolVersion = "2025-11-25", .capabilities = .{ .sampling = .null }, .clientInfo = .{ .name = "c", .version = "0" } });
    c.abortInitialize(); // no effect once initialized
    try std.testing.expect(c.isInitialized() and c.client_capabilities.sampling);
    try std.testing.expect(!c.beginInitialize());
    c.setLogLevel(.warning);

    // A new session starts from scratch.
    c.reset();
    try std.testing.expect(!c.isInitialized() and !c.client_capabilities.sampling);
    try std.testing.expectEqual(null, c.logLevel());
    try std.testing.expect(c.beginInitialize());
    c.reset();
}

test "a response that cannot be stored still wakes the request" {
    const io = std.testing.io;
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var c: Connection = .{ .gpa = failing.allocator() };
    defer c.reset();

    var pending: Pending = .{};
    const number = try c.addPending(io, &pending);
    var buffer: [request_id_prefix.len + 20]u8 = undefined;
    failing.fail_index = failing.alloc_index; // fail from now on
    try std.testing.expect(c.deliverResponse(io, requestId(&buffer, number), "{}"));
    try std.testing.expect(pending.done.isSet() and pending.out_of_memory and pending.response == null);
    c.removePending(io, number);
}
