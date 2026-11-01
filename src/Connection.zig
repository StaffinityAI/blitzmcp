//! State of one client connection: the negotiated lifecycle state and, when
//! requests are handled concurrently, the requests in flight in both
//! directions. Shared by the tasks that handle requests of the connection.

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

mode: Mode = .serial,
/// Allocates the keys of `in_flight` and the responses of `pending`.
gpa: std.mem.Allocator = undefined,

/// Whether the server has answered `initialize`. Requests other than
/// `initialize` and `ping` are rejected before that.
initialized: std.atomic.Value(bool) = .init(false),
/// Written before `initialized` is set and only read after it has been set.
client_capabilities: ClientCapabilities = .{},
/// The minimum log level requested via `logging/setLevel`, `no_log_level` if unset.
log_level: std.atomic.Value(u8) = .init(no_log_level),

/// Ids for requests to the client.
next_request_id: std.atomic.Value(i64) = .init(1),

/// Guards `in_flight`, `pending`, `closed` and `idle`.
mutex: std.Io.Mutex = .init,
/// Keyed by `idKey`. The keys are owned by the requests' tasks.
in_flight: std.StringHashMapUnmanaged(*InFlight) = .empty,
pending: std.AutoHashMapUnmanaged(i64, *Pending) = .empty,
/// Whether the client went away. No more responses will arrive.
closed: bool = false,
/// Set while no request is in flight.
idle: std.Io.Event = .is_set,

const no_log_level = std.math.maxInt(u8);

/// Frees the bookkeeping of a finished concurrent run and allows another run.
/// Asserts that no requests are in flight in either direction.
pub fn reset(c: *Connection) void {
    std.debug.assert(c.in_flight.count() == 0 and c.pending.count() == 0);
    c.in_flight.deinit(c.gpa);
    c.pending.deinit(c.gpa);
    c.in_flight = .empty;
    c.pending = .empty;
    c.closed = false;
}

pub fn logLevel(c: *const Connection) ?types.LoggingLevel {
    const level = c.log_level.load(.acquire);
    return if (level == no_log_level) null else @fromBackingInt(@intCast(level));
}

pub fn setLogLevel(c: *Connection, level: types.LoggingLevel) void {
    c.log_level.store(@backingInt(level), .release);
}

/// Must only be called once, before any request can run concurrently.
pub fn markInitialized(c: *Connection, params: types.InitializeRequestParams) void {
    std.debug.assert(!c.isInitialized());
    c.client_capabilities = .{
        .sampling = params.capabilities.sampling != null,
        .elicitation = params.capabilities.elicitation != null,
        .roots = params.capabilities.roots != null,
    };
    c.initialized.store(true, .release);
}

pub fn isInitialized(c: *const Connection) bool {
    return c.initialized.load(.acquire);
}

/// A unique string for a request id, used as the key of `in_flight`.
pub fn idKey(allocator: std.mem.Allocator, id: json_rpc.ID) std.mem.Allocator.Error![]u8 {
    return switch (id) {
        .number => |number| std.fmt.allocPrint(allocator, "n{d}", .{number}),
        .string => |string| std.fmt.allocPrint(allocator, "s{s}", .{string}),
    };
}

pub const RegisterError = std.mem.Allocator.Error || error{
    /// A request with the same id is still in flight.
    DuplicateId,
    /// `limit` requests are already in flight.
    TooManyRequests,
};

/// Registers a request from the client under `key` (see `idKey`). `key` and
/// `in_flight` must stay valid until `removeInFlight` is called with `key`.
pub fn addInFlight(c: *Connection, io: std.Io, key: []const u8, in_flight: *InFlight, limit: usize) RegisterError!void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.in_flight.count() >= limit) return error.TooManyRequests;
    const entry = try c.in_flight.getOrPut(c.gpa, key);
    if (entry.found_existing) return error.DuplicateId;
    entry.value_ptr.* = in_flight;
    c.idle.reset();
}

pub fn removeInFlight(c: *Connection, io: std.Io, key: []const u8) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    _ = c.in_flight.remove(key);
    if (c.in_flight.count() == 0) c.idle.set(io);
}

/// Handles `notifications/cancelled` from the client. Unknown ids are ignored,
/// the request may already have finished.
pub fn cancelInFlight(c: *Connection, io: std.Io, id: json_rpc.ID) std.mem.Allocator.Error!void {
    const lookup = try idKey(c.gpa, id);
    defer c.gpa.free(lookup);

    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    const in_flight = c.in_flight.get(lookup) orelse return;
    in_flight.canceled.store(true, .release);
    in_flight.done.set(io);
}

/// Registers a request to the client and returns its id. `pending` must stay
/// valid until `removePending` is called.
pub fn addPending(c: *Connection, io: std.Io, pending: *Pending) (std.mem.Allocator.Error || error{ConnectionClosed})!i64 {
    const id = c.next_request_id.fetchAdd(1, .monotonic);
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    if (c.closed) return error.ConnectionClosed;
    try c.pending.put(c.gpa, id, pending);
    return id;
}

pub fn removePending(c: *Connection, io: std.Io, id: i64) void {
    c.mutex.lockUncancelable(io);
    defer c.mutex.unlock(io);
    _ = c.pending.remove(id);
}

/// Hands a response from the client to the request waiting for it. Returns
/// `false` if no request with this id is waiting.
pub fn deliverResponse(c: *Connection, io: std.Io, id: json_rpc.ID, json_message: []const u8) bool {
    const number = switch (id) {
        .number => |number| number,
        .string => return false,
    };
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
    const gpa = std.testing.allocator;
    var c: Connection = .{ .gpa = gpa };
    defer c.reset();

    const key_a = try idKey(gpa, .{ .number = 1 });
    defer gpa.free(key_a);
    const key_b = try idKey(gpa, .{ .string = "1" });
    defer gpa.free(key_b);
    var a: InFlight = .{};
    var b: InFlight = .{};
    try c.addInFlight(io, key_a, &a, 2);
    try std.testing.expect(!c.idle.isSet());
    try std.testing.expectError(error.DuplicateId, c.addInFlight(io, key_a, &b, 2));
    try c.addInFlight(io, key_b, &b, 2);
    var d: InFlight = .{};
    try std.testing.expectError(error.TooManyRequests, c.addInFlight(io, "n2", &d, 2));

    try c.cancelInFlight(io, .{ .string = "1" });
    try std.testing.expect(b.canceled.load(.acquire) and b.done.isSet());
    try std.testing.expect(!a.canceled.load(.acquire));
    try c.cancelInFlight(io, .{ .number = 42 }); // unknown

    c.removeInFlight(io, key_a);
    try std.testing.expect(!c.idle.isSet());
    c.removeInFlight(io, key_b);
    try std.testing.expect(c.idle.isSet());
    try std.testing.expectEqual(0, c.in_flight.count());
}

test "pending requests" {
    const io = std.testing.io;
    var c: Connection = .{ .gpa = std.testing.allocator };
    defer c.reset();

    var pending: Pending = .{};
    const id = try c.addPending(io, &pending);
    try std.testing.expect(!c.deliverResponse(io, .{ .number = id + 1 }, "{}"));
    try std.testing.expect(c.deliverResponse(io, .{ .number = id }, "{\"x\":1}"));
    try std.testing.expect(pending.done.isSet());
    try std.testing.expectEqualStrings("{\"x\":1}", pending.response.?);
    std.testing.allocator.free(pending.response.?);
    c.removePending(io, id);

    var other: Pending = .{};
    const other_id = try c.addPending(io, &other);
    c.close(io);
    try std.testing.expect(other.done.isSet() and other.response == null);
    c.removePending(io, other_id);
    var late: Pending = .{};
    try std.testing.expectError(error.ConnectionClosed, c.addPending(io, &late));
}

test "a response that cannot be stored still wakes the request" {
    const io = std.testing.io;
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var c: Connection = .{ .gpa = failing.allocator() };
    defer c.reset();

    var pending: Pending = .{};
    const id = try c.addPending(io, &pending);
    failing.fail_index = failing.alloc_index; // fail from now on
    try std.testing.expect(c.deliverResponse(io, .{ .number = id }, "{}"));
    try std.testing.expect(pending.done.isSet() and pending.out_of_memory and pending.response == null);
    c.removePending(io, id);
}
